import CoreFoundation

/// The idle scheduler's own one-shot timer: it starts long idle periods and moves tasks past their
/// `maxDelay`. In the app an unposted precise run-loop timer (``MainRunLoopPreciseTimer``), never
/// queued behind the classes whose absence it waits for; tests fire a fake by hand.
public protocol IdlePeriodTimer: AnyObject {
    /// Fires `fire` once after `delay` nanoseconds, replacing any pending fire.
    @MainActor func arm(afterNanos delay: UInt64, _ fire: @escaping @MainActor () -> Void)
    /// Drops the pending fire.
    @MainActor func cancel()
}

/// The app's ``IdlePeriodTimer``: one `CFRunLoopTimer` on the main run loop in the common modes,
/// with no tolerance, made on the first arm and parked far in the future between arms (as
/// `CEFRunLoopPumpTimer`), so arming allocates no timer. It fires from the run loop itself, never
/// through a posted task.
///
/// Not actor-isolated and not `Sendable` (as ``RenderPassMeter``): its one owner, the main-actor
/// ``IdleScheduler``, holds it, so its deinit may invalidate the timer it made.
public final class MainRunLoopPreciseTimer: IdlePeriodTimer {
    private let slot: FireSlot
    private var timer: CFRunLoopTimer?
    /// Longer than any real wait: the timer repeats at this interval only so that it stays valid
    /// after a fire; every real fire date is set by ``arm(afterNanos:_:)``.
    private static let parkedInterval: CFTimeInterval = 1.0e10

    @MainActor
    /// A parked timer; ``arm(afterNanos:_:)`` sets its first fire.
    public init() {
        slot = FireSlot()
    }

    @MainActor
    /// Runs `fire` once on the main run loop `delay` nanoseconds from now, replacing a pending fire.
    public func arm(afterNanos delay: UInt64, _ fire: @escaping @MainActor () -> Void) {
        slot.fire = fire
        let date = CFAbsoluteTimeGetCurrent() + Double(delay) / 1_000_000_000
        if let timer {
            CFRunLoopTimerSetNextFireDate(timer, date)
            return
        }
        let slot = slot
        // wakeup-allow: the idle scheduler's one-shot period timer, parked between arms
        guard let made = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, date, Self.parkedInterval, 0, 0, { _ in
            // main-proof: the timer is only ever added to CFRunLoopGetMain(), whose callouts run on the main thread
            MainActor.assumeIsolated { slot.run() }
        }) else { return }
        CFRunLoopTimerSetTolerance(made, 0)
        CFRunLoopAddTimer(CFRunLoopGetMain(), made, .commonModes)
        timer = made
    }

    @MainActor
    /// Drops the pending fire, if any; the timer stays parked until the next ``arm(afterNanos:_:)``.
    public func cancel() {
        slot.fire = nil
        if let timer { CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + Self.parkedInterval) }
    }

    deinit {
        if let timer { CFRunLoopTimerInvalidate(timer) }
    }
}

/// The armed fire, shared with the run-loop callout (main thread only): one fire per arm.
@MainActor
private final class FireSlot {
    var fire: (@MainActor () -> Void)?

    func run() {
        let pending = fire
        fire = nil
        pending?()
    }
}
