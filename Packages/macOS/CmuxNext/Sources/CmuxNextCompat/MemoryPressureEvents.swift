/// The memory pressure level, from one ``MemoryPressureSource``, handed to every subscriber on the
/// main actor (event-driven, nothing polls).
///
/// Make one at the composition root with ``KernelMemoryPressureSource`` and inject it, so one source
/// serves every owner that reacts to pressure; a test passes a source it drives. Each subscriber keeps
/// the registration ``observe(_:)`` returns and stops when it releases it (on any thread) or cancels
/// it: a subscriber cancelled on the main actor gets no later event, not even later in a delivery
/// that is running, because cancelling removes the handler at once and each delivery looks a handler
/// up just before it calls it (see ``MainActorHandlers/call(_:)`` for a release on another thread).
/// The source starts in the init, or at ``start()`` for events made with `startsNow: false` (the app
/// starts its own after the first frame, p08-startup-098), and is cancelled in the deinit.
///
/// ```swift
/// let memoryPressure = MemoryPressureEvents(source: KernelMemoryPressureSource())
/// pressureObservation = memoryPressure.observe { [weak self] level in self?.pressureDidChange(level) }
/// ```
public final class MemoryPressureEvents: Sendable {
    private let handlers = MainActorHandlers<MemoryPressureLevel>()
    private let source: any MemoryPressureSource
    private let started = Atomic<Bool>(false)

    /// Starts `source` now, or at ``start()`` when `startsNow` is false, handing each level it reports
    /// to the subscribers.
    ///
    /// - Parameters:
    ///   - source: The pressure source; ``KernelMemoryPressureSource`` in the app.
    ///   - startsNow: False holds the source until ``start()``: until then nothing is delivered and
    ///     ``currentLevel`` is the source's level before its start (normal).
    public init(source: any MemoryPressureSource, startsNow: Bool = true) {
        self.source = source
        if startsNow { startSource() }
    }

    /// Starts a held source; does nothing when it started already. Subscribers made before it read normal,
    /// so a level other than normal at the start is handed to them, as a change would be.
    @MainActor public func start() {
        guard startSource() else { return }
        let level = source.currentLevel
        if level != .normal { handlers.call(level) }
    }

    /// Starts the source the first time; true when this call started it.
    @discardableResult
    private func startSource() -> Bool {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { return false }
        source.start { [handlers] level in handlers.call(level) }
        return true
    }

    /// The memory pressure level now, also before the first change (the source reads it at start,
    /// as Chrome's `SystemMemoryPressureEvaluator` sets its initial vote); inside a handler, the
    /// level that handler is given. Any thread.
    public var currentLevel: MemoryPressureLevel {
        source.currentLevel
    }

    /// Calls `handler` on the main actor with each memory pressure change until the returned
    /// registration is released or cancelled.
    ///
    /// - Parameter handler: Main-actor work for each new level (normal, warning or critical).
    /// - Returns: The registration; keep it in a stored property.
    public func observe(_ handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void)
        -> MainActorHandlerRegistration<MemoryPressureLevel> {
        handlers.add(handler)
    }

    deinit {
        source.cancel()
    }
}
