import Dispatch

/// The kernel's memory pressure: one dispatch source on the main queue, so each event reaches
/// ``MemoryPressureEvents`` on the main actor at once (event-driven, nothing polls).
///
/// Make one at the composition root and hand it to the app's one ``MemoryPressureEvents``. The
/// dispatch source exists only from ``start(delivering:)`` on, and it is active from the moment it
/// exists, so the instance is safe to release in every state: never started, cancelled before start,
/// or started and cancelled (libdispatch traps when an inactive source is released).
public final class KernelMemoryPressureSource: MemoryPressureSource {
    private struct State {
        var source: (any DispatchSourceMemoryPressure)?
        var isCancelled = false
    }

    // Lock carve-out: start and cancel run synchronously from MemoryPressureEvents' init and
    // nonisolated deinit on any thread; the critical sections set a flag and make, activate or
    // cancel the source, none of which waits or runs the event handler inline.
    private let state = Mutex(State())

    /// Makes an idle source; the dispatch source is made and activated in ``start(delivering:)``.
    public init() {}

    /// Makes the dispatch source, sets its event handler and activates it. Does nothing after
    /// ``cancel()`` or a second time.
    ///
    /// - Parameter deliver: Main-actor work for each new level.
    public func start(delivering deliver: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) {
        state.withLock { state in
            guard !state.isCancelled, state.source == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
            source.setEventHandler { [weak source] in
                guard let event = source?.data else { return }
                let level: MemoryPressureLevel = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
                // main-proof: the source delivers on the main queue (queue: .main).
                MainActor.assumeIsolated { deliver(level) }
            }
            source.activate()
            state.source = source
        }
    }

    /// Cancels the dispatch source: its event handler runs no more, and a later
    /// ``start(delivering:)`` does nothing.
    public func cancel() {
        state.withLock { state in
            state.isCancelled = true
            state.source?.cancel()
        }
    }
}
