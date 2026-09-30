internal import CmuxFoundation
public import CmuxTerminalPrediction
public import Foundation

/// Per-surface owner of predictive local echo.
///
/// The engine decides what may be drawn; this decides when it is asked. Three
/// events reach it, from three different threads' worth of libghostty: a
/// keystroke on the main thread, PTY output on the IO read thread, and a
/// presented frame from the renderer callback.
///
/// Only surfaces whose shell runs on another machine predict. A surface is
/// classified at its first keystroke after prediction starts for it, and a
/// local one costs one relaxed atomic load plus one set lookup per PTY read,
/// and a set lookup per keystroke. While the feature is off the PTY read path
/// costs only the atomic load.
@MainActor
public final class TerminalPredictionCenter {
    nonisolated public static let shared = TerminalPredictionCenter()

    /// Read from the IO thread before any copying happens, so a disabled
    /// feature costs one relaxed load per output chunk and nothing else.
    nonisolated private let enabledGate = AtomicBooleanGate(false)
    nonisolated private let origin = ContinuousClock.now
    /// Output batches between the IO thread and the main actor. An agent
    /// flooding the terminal must collapse into one hop per main-actor turn,
    /// not one hop per read. Accepts only surfaces classified remote.
    nonisolated private let inbox = PredictionOutputInbox()

    private var engines: [UUID: TerminalPredictionEngine] = [:]
    private var redrawHandlers: [UUID: @MainActor () -> Void] = [:]
    /// Reads whether each surface's terminal is in the alternate screen now.
    /// Consulted only when prediction starts for a surface, because the
    /// engine otherwise learns the mode from switches in output it sees.
    private var alternateScreenReaders: [UUID: @MainActor () -> Bool] = [:]
    /// Reads whether each surface's shell runs on another machine.
    private var remoteReaders: [UUID: @MainActor () -> Bool] = [:]
    /// Surfaces not classified, and whose alternate-screen mode has not been
    /// read, since prediction started for them. Both reads wait for the
    /// surface's first keystroke instead of running for every surface at once
    /// when the setting is turned on; the mode read serializes the viewport.
    private var surfacesAwaitingSeed: Set<UUID> = []
    private var isEnabled = false

    /// Fires at the earliest moment a drawn glyph ages out. A terminal that
    /// has gone quiet renders no frames, so nothing else would withdraw it.
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var settingObserver: (any NSObjectProtocol)?
    private var settingKey: String?
    private var settingDefaults: UserDefaults?
    private var settingDefaultValue = false

    nonisolated private init() {}

    /// Monotonic time since this process started predicting. Readable off the
    /// main actor so the PTY reader can stamp arrivals where they arrive.
    nonisolated private var now: PredictionInstant {
        ContinuousClock.now - origin
    }

    /// Binds the feature to a defaults key and keeps it current.
    ///
    /// The key is passed in rather than read from the setting catalog because
    /// this package does not depend on it; the app owns the catalog.
    ///
    /// - Parameter defaultValue: The catalog default, used while the key is
    ///   unset. `UserDefaults.bool(forKey:)` would read an unset key as off.
    public func bindEnabledSetting(
        userDefaultsKey: String,
        defaultValue: Bool,
        defaults: UserDefaults = .standard
    ) {
        if let settingObserver {
            NotificationCenter.default.removeObserver(settingObserver)
        }
        settingKey = userDefaultsKey
        settingDefaults = defaults
        settingDefaultValue = defaultValue
        refreshEnabledFromSetting()
        // The closure captures nothing but the singleton: `UserDefaults` is not
        // Sendable, so the store stays main-actor state and is read there.
        settingObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                TerminalPredictionCenter.shared.refreshEnabledFromSetting()
            }
        }
    }

    private func refreshEnabledFromSetting() {
        guard let settingKey, let settingDefaults else { return }
        setEnabled(settingDefaults.object(forKey: settingKey) as? Bool ?? settingDefaultValue)
    }

    // MARK: Lifecycle

    /// Starts predicting for a surface.
    ///
    /// - Parameters:
    ///   - isRemote: Reads whether the surface's shell runs on another
    ///     machine. Called with the alternate-screen read, once per
    ///     registration or enable; a runtime surface does not change machines.
    ///   - isAlternateScreen: Reads whether the terminal is in the alternate
    ///     screen right now. Called at the first keystroke after prediction
    ///     starts for this surface (registered while the setting is on, or
    ///     the setting turned on), so a full-screen app that was already open
    ///     is not predicted inside.
    ///   - redraw: Called on the main actor whenever the drawn set changed.
    public func register(
        surfaceID: UUID,
        isRemote: @escaping @MainActor () -> Bool,
        isAlternateScreen: @escaping @MainActor () -> Bool,
        redraw: @escaping @MainActor () -> Void
    ) {
        // A re-registration starts from scratch, including classification.
        inbox.forget(surfaceID: surfaceID)
        engines[surfaceID] = TerminalPredictionEngine(isEnabled: isEnabled)
        redrawHandlers[surfaceID] = redraw
        remoteReaders[surfaceID] = isRemote
        alternateScreenReaders[surfaceID] = isAlternateScreen
        if isEnabled { surfacesAwaitingSeed.insert(surfaceID) }
    }

    /// Classifies the surface, and for a remote one starts scanning its
    /// output and seeds the alternate screen. Output from before this was
    /// never scanned, so the mode comes from the terminal; output teed after
    /// the inbox accepts the surface applies on top of it.
    ///
    /// The mode read can find a stale surface and tear it down, which
    /// unregisters it synchronously, so callers recheck the engine afterwards.
    private func seedIfNeeded(surfaceID: UUID) {
        guard surfacesAwaitingSeed.remove(surfaceID) != nil,
              let readRemote = remoteReaders[surfaceID],
              readRemote() else { return }
        engines[surfaceID]?.isRemoteSurface = true
        inbox.accept(surfaceID: surfaceID)
        guard let readAlternateScreen = alternateScreenReaders[surfaceID] else { return }
        let isActive = readAlternateScreen()
        engines[surfaceID]?.seedAlternateScreen(isActive)
    }

    /// Classifies a surface again at its next keystroke, because the machine
    /// its shell runs on may have changed: a remote session registered after
    /// the surface was first typed into, or it ended. Anything drawn is
    /// withdrawn and the surface stops being scanned until then.
    public func surfaceMachineMayHaveChanged(surfaceID: UUID) {
        guard isEnabled, engines[surfaceID] != nil else { return }
        inbox.forget(surfaceID: surfaceID)
        engines[surfaceID] = TerminalPredictionEngine(isEnabled: true)
        expiryTasks.removeValue(forKey: surfaceID)?.cancel()
        surfacesAwaitingSeed.insert(surfaceID)
        redrawHandlers[surfaceID]?()
    }

    /// Stops predicting for a surface whose runtime is gone.
    ///
    /// Called from the byte-tee `dropSurface` hook rather than from the view,
    /// because every path that frees a runtime surface (teardown, hibernation,
    /// stale-pointer quarantine, model deinit) already goes through it, and
    /// the view only holds the surface weakly. Synchronous, so a surface
    /// recreated in the same turn re-registers after this, not before.
    public func unregister(surfaceID: UUID) {
        inbox.forget(surfaceID: surfaceID)
        engines.removeValue(forKey: surfaceID)
        expiryTasks.removeValue(forKey: surfaceID)?.cancel()
        // With the engine gone `expiring` returns nothing, so this redraw
        // hides any glyph still drawn over a view that outlives its runtime.
        alternateScreenReaders.removeValue(forKey: surfaceID)
        remoteReaders.removeValue(forKey: surfaceID)
        surfacesAwaitingSeed.remove(surfaceID)
        redrawHandlers.removeValue(forKey: surfaceID)?()
    }

    /// Re-arms the withdrawal deadline for whatever is currently drawn.
    private func scheduleExpiry(surfaceID: UUID) {
        expiryTasks.removeValue(forKey: surfaceID)?.cancel()
        guard let deadline = engines[surfaceID]?.nextExpiry else { return }
        let delay = deadline - now
        guard delay > .zero else {
            withdrawExpired(surfaceID: surfaceID)
            return
        }
        expiryTasks[surfaceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.withdrawExpired(surfaceID: surfaceID)
        }
    }

    private func withdrawExpired(surfaceID: UUID) {
        expiryTasks.removeValue(forKey: surfaceID)
        guard engines[surfaceID] != nil else { return }
        if engines[surfaceID]?.tick(at: now) == true {
            redrawHandlers[surfaceID]?()
        }
        scheduleExpiry(surfaceID: surfaceID)
    }

    /// Applies the user setting. Turning it off withdraws everything already
    /// drawn rather than leaving glyphs stranded over the grid.
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        enabledGate.storeRelease(enabled)
        if !enabled {
            surfacesAwaitingSeed.removeAll()
            inbox.forgetAll()
        }
        for surfaceID in engines.keys {
            engines[surfaceID]?.isEnabled = enabled
            if enabled {
                surfacesAwaitingSeed.insert(surfaceID)
            } else {
                // A fresh engine has no pending glyphs and no stale echo run.
                engines[surfaceID] = TerminalPredictionEngine(isEnabled: false)
            }
            redrawHandlers[surfaceID]?()
        }
    }

    // MARK: Events

    /// Whether keystrokes into this surface can be predicted: the feature is
    /// on and the surface is remote, or not classified yet. Read on the typing
    /// path before any work happens, so a local surface costs a lookup.
    public func predictsInput(surfaceID: UUID) -> Bool {
        guard isEnabled else { return false }
        return surfacesAwaitingSeed.contains(surfaceID)
            || engines[surfaceID]?.isRemoteSurface == true
    }

    /// The byte a keystroke is about to put on the PTY, or `nil` for every key
    /// whose effect on the screen is not knowable.
    public func typed(printableASCII byte: UInt8?, surfaceID: UUID) {
        guard isEnabled, engines[surfaceID] != nil else { return }
        seedIfNeeded(surfaceID: surfaceID)
        guard engines[surfaceID]?.isRemoteSurface == true else { return }
        let changed = engines[surfaceID]?.typed(printableASCII: byte, at: now) == true
        trace(surfaceID: surfaceID, "key \(byte.map { Self.escaped([$0]) } ?? "(untracked)")", changed: changed)
        if changed {
            redrawHandlers[surfaceID]?()
        }
        scheduleExpiry(surfaceID: surfaceID)
    }

    /// A Backspace, whichever byte the key sends. Retracts the newest glyph
    /// the remote has not echoed, or withdraws when there is none.
    public func typedBackspace(surfaceID: UUID) {
        guard isEnabled, engines[surfaceID] != nil else { return }
        seedIfNeeded(surfaceID: surfaceID)
        guard engines[surfaceID]?.isRemoteSurface == true else { return }
        let changed = engines[surfaceID]?.typedBackspace(at: now) == true
        trace(surfaceID: surfaceID, "backspace", changed: changed)
        if changed {
            redrawHandlers[surfaceID]?()
        }
        scheduleExpiry(surfaceID: surfaceID)
    }

    /// Ctrl-U, Ctrl-W or Option-Backspace: a key that deletes more than one
    /// character. Glyphs still in flight are drawn blank until the remote's
    /// erase lands instead of flashing back as their echoes arrive.
    public func typedLineErase(surfaceID: UUID) {
        guard isEnabled, engines[surfaceID] != nil else { return }
        seedIfNeeded(surfaceID: surfaceID)
        guard engines[surfaceID]?.isRemoteSurface == true else { return }
        let changed = engines[surfaceID]?.typedLineErase(at: now) == true
        trace(surfaceID: surfaceID, "line erase", changed: changed)
        if changed {
            redrawHandlers[surfaceID]?()
        }
        scheduleExpiry(surfaceID: surfaceID)
    }

    /// Input that reached the surface without passing through the keystroke
    /// path: a paste, dropped text, or text and keys sent over the socket or
    /// from a paired device. Withdraws what is drawn, because its echo moves
    /// the cursor by an amount the engine cannot know.
    public func sentUntrackedInput(surfaceID: UUID) {
        guard isEnabled, engines[surfaceID]?.isRemoteSurface == true else { return }
        let changed = engines[surfaceID]?.sentUntrackedInput(at: now) == true
        trace(surfaceID: surfaceID, "untracked input", changed: changed)
        if changed {
            redrawHandlers[surfaceID]?()
        }
        scheduleExpiry(surfaceID: surfaceID)
    }

    /// Raw PTY output, from libghostty's tee on the IO read thread.
    ///
    /// nonisolated because the tee cannot hop: it runs ahead of the VT parser
    /// and must not block it. The inbox copies the bytes, and only for a
    /// remote surface, because the buffer is only valid for the duration of
    /// the callback.
    nonisolated public func consumeOutput(surfaceID: UUID, bytes: UnsafeBufferPointer<UInt8>) {
        guard enabledGate.loadRelaxed(), !bytes.isEmpty else { return }
        let needsDrain = inbox.deposit(
            surfaceID: surfaceID,
            bytes: bytes,
            at: now
        )
        guard needsDrain else { return }
        Task { @MainActor [weak self] in
            self?.drainOutput()
        }
    }

    private func drainOutput() {
        for (surfaceID, arrivals) in inbox.drain() {
            guard engines[surfaceID] != nil else { continue }
            let changed = observe(arrivals, surfaceID: surfaceID)
            // Output that took blanks away is not on screen until the next
            // frame; the overlay stays as it is until then.
            if changed, !holdsLayoutUntilFrame(surfaceID: surfaceID) { redrawHandlers[surfaceID]?() }
            scheduleExpiry(surfaceID: surfaceID)
        }
    }

    private func observe(_ arrivals: [PredictionOutputBatch], surfaceID: UUID) -> Bool {
        var changed = false
        for arrival in arrivals {
            if arrival.followsDroppedOutput {
                changed = engines[surfaceID]?.missedOutput(at: arrival.instant) == true || changed
                trace(surfaceID: surfaceID, "dropped output before this batch", changed: changed)
            }
            let redraws = engines[surfaceID]?.observedOutput(
                arrival.bytes,
                at: arrival.instant
            ) == true
            trace(surfaceID: surfaceID, "out \(Self.escaped(arrival.bytes))", changed: redraws)
            changed = redraws || changed
        }
        return changed
    }

    /// Whether the overlay should stay exactly where it is until the next
    /// presented frame, because output the frame on screen predates took
    /// blanks away.
    public func holdsLayoutUntilFrame(surfaceID: UUID) -> Bool {
        engines[surfaceID]?.holdsLayoutUntilFrame == true
    }

    #if DEBUG
    /// Dev builds append every keystroke and output batch a remote surface's
    /// engine sees to /tmp/cmux-prediction-trace.log while
    /// /tmp/cmux-prediction-trace.on exists, with the glyphs drawn after it.
    /// That is how a withdrawal seen on screen is traced to the bytes behind it.
    private let traceFlagPath = "/tmp/cmux-prediction-trace.on"
    private lazy var traceHandle: FileHandle? = {
        let path = "/tmp/cmux-prediction-trace.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }()
    #endif

    private func trace(surfaceID: UUID, _ event: @autoclosure () -> String, changed: Bool) {
        #if DEBUG
        guard FileManager.default.fileExists(atPath: traceFlagPath),
              let engine = engines[surfaceID] else { return }
        let glyphs = engine.glyphs.map { glyph -> String in
            switch glyph.standing {
            case .speculative: "\(glyph.character)"
            case .confirmed: "\(glyph.character)!"
            case .erased: "_"
            }
        }.joined()
        let line = String(
            format: "%.3f %@ %@%@ -> [%@] %@\n",
            Date().timeIntervalSince1970,
            String(surfaceID.uuidString.prefix(8)),
            event(),
            changed ? " (redraw)" : "",
            glyphs,
            String(describing: engine.status(at: now))
        )
        traceHandle?.write(Data(line.utf8))
        #endif
    }

    nonisolated private static func escaped(_ bytes: some Sequence<UInt8>) -> String {
        var text = ""
        for byte in bytes {
            switch byte {
            case 0x20...0x7E where byte != UInt8(ascii: "\\"): text.append(Character(UnicodeScalar(byte)))
            case 0x1B: text += "\\e"
            case 0x0D: text += "\\r"
            case 0x0A: text += "\\n"
            case 0x08: text += "\\b"
            case 0x07: text += "\\a"
            default: text += String(format: "\\x%02x", byte)
            }
            if text.count > 400 { text += "..."; break }
        }
        return text
    }

    /// A rendered frame reached the screen, so confirmed glyphs can retire.
    public func presentedFrame(surfaceID: UUID) {
        guard isEnabled, engines[surfaceID] != nil else { return }
        // Catch up on output the parser has already applied first, so the
        // engine and the grid the frame showed agree before anything
        // retires or the overlay re-anchors.
        let caughtUp = observe(inbox.drain(surfaceID: surfaceID), surfaceID: surfaceID)
        let retired = engines[surfaceID]?.presentedFrame(at: now) == true
        if caughtUp || retired {
            redrawHandlers[surfaceID]?()
        }
        scheduleExpiry(surfaceID: surfaceID)
    }

    /// Withdraws anything that has aged out. Called from the draw path, so a
    /// surface that stopped receiving events still lets go of its glyphs.
    public func expiring(surfaceID: UUID) -> [PredictedGlyph] {
        guard engines[surfaceID] != nil else { return [] }
        engines[surfaceID]?.tick(at: now)
        return engines[surfaceID]?.glyphs ?? []
    }

    public func status(surfaceID: UUID) -> TerminalPredictionEngine.Status {
        engines[surfaceID]?.status(at: now) ?? .disabled
    }

    public func observedEchoLatency(surfaceID: UUID) -> Duration? {
        engines[surfaceID]?.observedEchoLatency
    }
}
