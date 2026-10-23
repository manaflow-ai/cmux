import Dispatch

/// The kernel's memory pressure, observed through one main-queue dispatch source that calls only
/// its subscribers, on the main actor (event-driven, nothing polls).
///
/// Make one at the composition root and inject it, so the app keeps one source however many
/// owners react to pressure. Each subscriber keeps the registration ``observe(_:)`` returns and
/// stops when it releases it (on any thread) or cancels it; a cancelled subscriber gets no later
/// event, because events are delivered synchronously on the main queue. The source starts with
/// the first subscriber and is cancelled when this object goes.
///
/// ```swift
/// pressureObservation = memoryPressure.observe { [weak self] level in self?.pressureDidChange(level) }
/// ```
public final class MemoryPressureEvents: Sendable {
    private let handlers = MainActorHandlers<KernelMemoryPressure>()
    /// The dispatch source, made on the first ``observe(_:)``; in a Mutex so that any thread may
    /// subscribe and the deinit cancels it on any thread.
    private let source = Mutex<(any DispatchSourceMemoryPressure)?>(nil)

    /// Makes the observer; the dispatch source starts with the first subscriber.
    public init() {}

    /// Calls `handler` on the main actor with each memory pressure change until the returned
    /// registration is released or cancelled.
    ///
    /// - Parameter handler: Main-actor work for each new level (normal, warning or critical).
    /// - Returns: The registration; keep it in a stored property.
    public func observe(_ handler: @escaping @MainActor @Sendable (KernelMemoryPressure) -> Void)
        -> MainActorHandlerRegistration<KernelMemoryPressure> {
        let registration = handlers.add(handler)
        source.withLock { source in
            if source == nil { source = makeMainQueueSource(calling: handlers) }
        }
        return registration
    }

    deinit {
        source.withLock { $0?.cancel() }
    }
}

/// A started memory pressure source on the main queue that hands each event to `handlers`.
private func makeMainQueueSource(calling handlers: MainActorHandlers<KernelMemoryPressure>)
    -> any DispatchSourceMemoryPressure {
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    source.setEventHandler { [weak source] in
        guard let event = source?.data else { return }
        let level: KernelMemoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
        // main-proof: the source delivers on the main queue (queue: .main).
        MainActor.assumeIsolated { handlers.call(level) }
    }
    source.activate()
    return source
}
