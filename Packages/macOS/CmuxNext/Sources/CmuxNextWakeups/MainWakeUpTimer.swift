import CoreFoundation

/// The timer seam of ``MainWakeUpQueue``. It lives in the queue's `Mutex` and is called only with that
/// lock held (from any thread), so it needs no synchronization of its own and is not `Sendable`.
protocol MainWakeUpTimer: AnyObject {
    /// Fires once at `date` (uptime ns; `now` is the uptime read just before), with `tolerance` ns of
    /// slack after it.
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64)
    /// Cancels the pending fire.
    func park()
}

/// The production timer: one repeating `CFRunLoopTimer` on the main run loop in common modes (it also
/// fires during menu tracking, live resize and modal panels), parked at a far fire date between arms.
///
/// The callout does not run the fire itself; it queues it as a common-modes run-loop block, which
/// CFRunLoop runs right after its timers in the same pass. CFRunLoop never fires a timer whose callout
/// is still running, so a fire inside the callout that spins a nested run loop would stop every later
/// deadline. Chromium's `MessagePumpCFRunLoopBase::RunDelayedWorkTimer` (message_pump_mac.mm, before
/// the rename to message_pump_apple.mm) likewise signalled its work source "rather than running work
/// directly".
final class MainRunLoopWakeUpTimer: MainWakeUpTimer {
    /// Longer than any real wait: the timer repeats at this interval only so that it stays valid after a
    /// fire; every real fire date is set by `arm`.
    private static let parkedInterval: CFTimeInterval = 1.0e10
    private let timer: CFRunLoopTimer

    init(fire: @escaping MainWakeUpQueue.Action) {
        // wakeup-allow: deadline MainWakeUpQueue, the one main-thread deadline timer (parked between arms)
        timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, Self.fireDate(after: Self.parkedInterval), Self.parkedInterval, 0, 0
        ) { _ in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                // main-proof: the block is queued on CFRunLoopGetMain(), whose blocks run on the main thread.
                MainActor.assumeIsolated { fire() }
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
    }

    deinit {
        CFRunLoopTimerInvalidate(timer)
    }

    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {
        let delay = date > now ? Double(date - now) / 1e9 : 0
        CFRunLoopTimerSetTolerance(timer, Double(tolerance) / 1e9)
        // wakeup-allow: deadline MainWakeUpQueue, the earliest pending main-thread deadline
        CFRunLoopTimerSetNextFireDate(timer, Self.fireDate(after: delay))
    }

    func park() {
        CFRunLoopTimerSetNextFireDate(timer, Self.fireDate(after: Self.parkedInterval))
    }

    /// `delay` s from now as a fire date: CF keeps only the delay, on uptime (CFRunLoop.c, message_pump_apple.mm).
    private static func fireDate(after delay: CFTimeInterval) -> CFAbsoluteTime {
        CFAbsoluteTimeGetCurrent() + delay // wall-clock: CFRunLoopTimer fire dates are CFAbsoluteTime
    }
}
