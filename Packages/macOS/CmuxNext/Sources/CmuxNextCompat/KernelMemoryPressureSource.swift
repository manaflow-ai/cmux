import Dispatch

/// The kernel's memory pressure: one dispatch source on the main queue, so each event reaches
/// ``MemoryPressureEvents`` on the main actor at once (event-driven, nothing polls).
///
/// Make one at the composition root and hand it to the app's one ``MemoryPressureEvents``.
public final class KernelMemoryPressureSource: MemoryPressureSource {
    // crash-allow: a dispatch source is thread-safe (libdispatch: setEventHandler, activate and cancel run on any thread), and this let never changes.
    private nonisolated(unsafe) let source: any DispatchSourceMemoryPressure

    /// Makes the dispatch source; it stays inactive until ``start(delivering:)``.
    public init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    }

    /// Sets the event handler and activates the source.
    ///
    /// - Parameter deliver: Main-actor work for each new level.
    public func start(delivering deliver: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) {
        let source = self.source
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            let level: MemoryPressureLevel = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            // main-proof: the source delivers on the main queue (queue: .main).
            MainActor.assumeIsolated { deliver(level) }
        }
        source.activate()
    }

    /// Cancels the dispatch source: its event handler runs no more.
    public func cancel() {
        source.cancel()
    }
}
