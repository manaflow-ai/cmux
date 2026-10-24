import CoreFoundation
import Darwin

/// Times the main run loop's before-waiting phase: AppKit's layout and display and the Core
/// Animation commit of what the pass changed, the cost a frame's scheduled work leaves behind it
/// that no task body measures. Each pass is reported to `onPass` in nanoseconds; the
/// ``MainWorkScheduler`` charges it to the next frame's budget (``MainFrameBudget/noteRenderPass(nanos:)``).
///
/// Two observers on the main run loop in the common modes (event tracking included): the first
/// at the lowest order notes the phase's start, the last at the highest order reports its length,
/// so every observer of the phase (the commit's included) runs between them. They are on the run
/// loop only between ``start()`` and ``stop()``: while the budgeted display link exists, the only
/// time a frame's scheduled work is held to the budget, so an idle app runs no observer.
///
/// Not actor-isolated and not `Sendable`: its one owner (the ``MainWorkScheduler``, main actor)
/// holds it, so its deinit may invalidate the observers it made.
final class RenderPassMeter {
    private let observers: [CFRunLoopObserver]
    private var started = false

    /// - Parameters:
    ///   - uptimeNanos: The clock (`CLOCK_UPTIME_RAW` nanoseconds, as the budget's).
    ///   - onPass: Receives each pass's length, on the main thread.
    @MainActor
    init(uptimeNanos: @escaping @MainActor @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
         onPass: @escaping @MainActor @Sendable (UInt64) -> Void) {
        let box = PhaseStart()
        let first = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.min) { _, _ in
            // main-proof: the observer is only ever added to CFRunLoopGetMain(), whose callouts run on the main thread
            MainActor.assumeIsolated { box.start = uptimeNanos() }
        }
        let last = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            // main-proof: the observer is only ever added to CFRunLoopGetMain(), whose callouts run on the main thread
            MainActor.assumeIsolated {
                guard box.start != 0 else { return }
                onPass(uptimeNanos() &- box.start)
                box.start = 0
            }
        }
        observers = [first, last].compactMap { $0 }
    }

    /// Starts timing passes (no effect while started).
    func start() {
        guard !started else { return }
        started = true
        for observer in observers { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }

    /// Stops timing passes (no effect while stopped).
    func stop() {
        guard started else { return }
        started = false
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }

    deinit {
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
    }
}

/// The phase's start, shared by the meter's two observers (main thread only).
@MainActor
private final class PhaseStart {
    var start: UInt64 = 0
}
