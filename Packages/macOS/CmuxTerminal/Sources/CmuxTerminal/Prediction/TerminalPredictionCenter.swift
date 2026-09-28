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
    public func bindEnabledSetting(
        userDefaultsKey: String,
        defaults: UserDefaults = .standard
    ) {
        if let settingObserver {
            NotificationCenter.default.removeObserver(settingObserver)
        }
        settingKey = userDefaultsKey
        settingDefaults = defaults
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
        setEnabled(settingDefaults.bool(forKey: settingKey))
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
        if engines[surfaceID]?.typed(printableASCII: byte, at: now) == true {
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
        if engines[surfaceID]?.typedBackspace(at: now) == true {
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
        if engines[surfaceID]?.sentUntrackedInput(at: now) == true {
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
            var changed = false
            for arrival in arrivals {
                changed = engines[surfaceID]?.observedOutput(
                    arrival.bytes,
                    at: arrival.instant
                ) == true || changed
            }
            if changed { redrawHandlers[surfaceID]?() }
            scheduleExpiry(surfaceID: surfaceID)
        }
    }

    /// A rendered frame reached the screen, so confirmed glyphs can retire.
    public func presentedFrame(surfaceID: UUID) {
        guard isEnabled, engines[surfaceID] != nil else { return }
        if engines[surfaceID]?.presentedFrame(at: now) == true {
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
