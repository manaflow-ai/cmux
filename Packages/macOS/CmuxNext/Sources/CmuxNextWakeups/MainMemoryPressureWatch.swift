import Foundation

/// Calls main-actor work on each memory-pressure event of the kinds it watches, until it is
/// released. An event from the system, never a poll.
///
/// The one place a memory-pressure source on the main queue hands its events to main-actor code
/// (an owner drops its caches there). Each event runs `changed` on the main thread, synchronously
/// in the event, in the main queue's order. A callback, not an `AsyncStream`: a consumer task
/// would run the work as a later main-actor job instead. Releasing the watch cancels the source
/// (`DispatchSource.cancel()` is thread-safe), so the owner needs no deinit.
///
/// ```swift
/// memoryPressure = MainMemoryPressureWatch([.warning, .critical]) { [weak self] in self?.dropCaches() }
/// ```
public final class MainMemoryPressureWatch {
    private let source: any DispatchSourceMemoryPressure

    /// Starts watching for `events`.
    ///
    /// - Parameters:
    ///   - events: The pressure levels that call `changed` (for example `[.warning, .critical]`).
    ///   - changed: Main-actor work for each event, on the main thread.
    public init(_ events: DispatchSource.MemoryPressureEvent, _ changed: @escaping @MainActor @Sendable () -> Void) {
        // wakeup-allow: a system memory-pressure event (no timer, no poll); DispatchSource has no async-native replacement.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: events, queue: .main)
        source.setEventHandler {
            // main-proof: the source delivers on the main queue (queue: .main above).
            MainActor.assumeIsolated { changed() }
        }
        self.source = source
        source.activate()
    }

    deinit {
        source.cancel()
    }
}
