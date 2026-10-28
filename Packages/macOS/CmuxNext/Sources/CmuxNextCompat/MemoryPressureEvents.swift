/// The memory pressure level, from one ``MemoryPressureSource``, handed to every subscriber on the
/// main actor (event-driven, nothing polls).
///
/// Make one at the composition root with ``KernelMemoryPressureSource`` and inject it, so one source
/// serves every owner that reacts to pressure; a test passes a source it drives. Each subscriber keeps
/// the registration ``observe(_:)`` returns and stops when it releases it (on any thread) or cancels
/// it: a subscriber cancelled on the main actor gets no later event, not even later in a delivery
/// that is running, because cancelling removes the handler at once and each delivery looks a handler
/// up just before it calls it (see ``MainActorHandlers/call(_:)`` for a release on another thread).
/// The source starts in the init and is cancelled in the deinit.
///
/// ```swift
/// let memoryPressure = MemoryPressureEvents(source: KernelMemoryPressureSource())
/// pressureObservation = memoryPressure.observe { [weak self] level in self?.pressureDidChange(level) }
/// ```
public final class MemoryPressureEvents: Sendable {
    private let handlers = MainActorHandlers<MemoryPressureLevel>()
    private let source: any MemoryPressureSource

    /// Starts `source`, handing each level it reports to the subscribers.
    ///
    /// - Parameter source: The pressure source; ``KernelMemoryPressureSource`` in the app.
    public init(source: any MemoryPressureSource) {
        self.source = source
        source.start { [handlers] level in handlers.call(level) }
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
