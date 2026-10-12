import CoreFoundation
import Foundation

/// The one timer that drives the external message pump. The pump re-arms it
/// for each CEF request instead of creating timers, so a new request always
/// replaces the previous fire date.
protocol CEFPumpTimer: AnyObject {
    /// Called on the main thread when the timer fires.
    var onFire: (() -> Void)? { get set }
    /// Fires once, `delay` seconds from now (0 = on the next run loop pass).
    /// `tolerance` lets the system coalesce the wakeup with others.
    func arm(after delay: TimeInterval, tolerance: TimeInterval)
    /// Cancels the pending fire, if any.
    func disarm()
    /// Removes the timer from the run loop for good.
    func invalidate()
}

/// A `CFRunLoopTimer` on the main run loop in common modes, so it also fires
/// during menu tracking, live resize and modal panels. It stays in the run
/// loop while disarmed (fire date in the distant future), so arming costs no
/// allocation. Owned and cancellable; there is no `asyncAfter`.
final class CEFRunLoopPumpTimer: CEFPumpTimer {
    var onFire: (() -> Void)?
    private var timer: CFRunLoopTimer?
    /// Longer than any real wait: the timer repeats at this interval only so
    /// that it stays valid after a fire; every real fire date is set by `arm`.
    private static let parkedInterval: CFTimeInterval = 1.0e10

    init() {
        // wakeup-allow: CEF external pump, one-shot at the delay CEF requests (parked between arms)
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + Self.parkedInterval, Self.parkedInterval, 0, 0
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFire?() } // main-proof: the timer is added only to CFRunLoopGetMain() (below)
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
        self.timer = timer
    }

    func arm(after delay: TimeInterval, tolerance: TimeInterval) {
        guard let timer else { return }
        CFRunLoopTimerSetTolerance(timer, tolerance)
        // wakeup-allow: CEF external pump, one-shot at the delay CEF requests
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + max(0, delay))
    }

    func disarm() {
        guard let timer else { return }
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + Self.parkedInterval)
    }

    func invalidate() {
        if let timer { CFRunLoopTimerInvalidate(timer) }
        timer = nil
        onFire = nil
    }
}
