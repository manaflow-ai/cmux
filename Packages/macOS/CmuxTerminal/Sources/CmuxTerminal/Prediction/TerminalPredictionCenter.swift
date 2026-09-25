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
/// While the feature is off -- which is the default -- the only cost on the PTY
/// read path is one relaxed atomic load.
@MainActor
public final class TerminalPredictionCenter {
    nonisolated public static let shared = TerminalPredictionCenter()

    /// Read from the IO thread before any copying happens, so a disabled
    /// feature costs one relaxed load per output chunk and nothing else.
    nonisolated private let enabledGate = AtomicBooleanGate(false)
    nonisolated private let origin = ContinuousClock.now
    /// Output batches between the IO thread and the main actor. An agent
    /// flooding the terminal must collapse into one hop per main-actor turn,
    /// not one hop per read.
    nonisolated private let inbox = PredictionOutputInbox()

    private var engines: [UUID: TerminalPredictionEngine] = [:]
    private var redrawHandlers: [UUID: @MainActor () -> Void] = [:]
    /// Reads whether each surface's terminal is in the alternate screen now.
    /// Consulted only when prediction starts for a surface, because the
    /// engine otherwise learns the mode from switches in output it sees.
    private var alternateScreenReaders: [UUID: @MainActor () -> Bool] = [:]
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
    ///   - isAlternateScreen: Reads whether the terminal is in the alternate
    ///     screen right now. Called when prediction starts for this surface
    ///     (here while the setting is on, or when it is turned on), so a
    ///     full-screen app that was already open is not predicted inside.
    ///   - redraw: Called on the main actor whenever the drawn set changed.
    public func register(
        surfaceID: UUID,
        isAlternateScreen: @escaping @MainActor () -> Bool,
        redraw: @escaping @MainActor () -> Void
    ) {
        engines[surfaceID] = TerminalPredictionEngine(isEnabled: isEnabled)
        redrawHandlers[surfaceID] = redraw
        alternateScreenReaders[surfaceID] = isAlternateScreen
        if isEnabled { seedAlternateScreen(surfaceID: surfaceID) }
    }

    /// Output from before prediction started was never scanned, so the mode
    /// comes from the terminal. Anything teed since arrives after this and
    /// applies on top of it.
    private func seedAlternateScreen(surfaceID: UUID) {
        guard let read = alternateScreenReaders[surfaceID] else { return }
        engines[surfaceID]?.seedAlternateScreen(read())
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
        for surfaceID in engines.keys {
            engines[surfaceID]?.isEnabled = enabled
            if enabled {
                seedAlternateScreen(surfaceID: surfaceID)
            } else {
                // A fresh engine has no pending glyphs and no stale echo run.
                engines[surfaceID] = TerminalPredictionEngine(isEnabled: false)
            }
            redrawHandlers[surfaceID]?()
        }
    }

    // MARK: Events

    /// Whether any surface is predicting. Read on the typing path before any
    /// work happens, so the default-off case costs one bool.
    public var isPredictionEnabled: Bool { isEnabled }

    /// The byte a keystroke is about to put on the PTY, or `nil` for every key
    /// whose effect on the screen is not knowable.
    public func typed(printableASCII byte: UInt8?, surfaceID: UUID) {
        guard isEnabled, engines[surfaceID] != nil else { return }
        if engines[surfaceID]?.typed(printableASCII: byte, at: now) == true {
            redrawHandlers[surfaceID]?()
        }
        scheduleExpiry(surfaceID: surfaceID)
    }

    /// A Backspace, whichever byte the key sends. Retracts the newest glyph
    /// the remote has not echoed, or withdraws when there is none.
    public func typedBackspace(surfaceID: UUID) {
        guard isEnabled, engines[surfaceID] != nil else { return }
        if engines[surfaceID]?.typedBackspace(at: now) == true {
            redrawHandlers[surfaceID]?()
        }
        scheduleExpiry(surfaceID: surfaceID)
    }

    /// Raw PTY output, from libghostty's tee on the IO read thread.
    ///
    /// nonisolated because the tee cannot hop: it runs ahead of the VT parser
    /// and must not block it. The bytes are copied here because the buffer is
    /// only valid for the duration of the callback.
    nonisolated public func consumeOutput(surfaceID: UUID, bytes: UnsafeBufferPointer<UInt8>) {
        guard enabledGate.loadRelaxed(), !bytes.isEmpty else { return }
        let needsDrain = inbox.deposit(
            surfaceID: surfaceID,
            bytes: Array(bytes),
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
