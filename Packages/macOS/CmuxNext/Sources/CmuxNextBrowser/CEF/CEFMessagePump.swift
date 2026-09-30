import CoreFoundation
import Foundation

/// Drives `CefDoMessageLoopWork` from one timer on the main run loop in
/// common modes (so it keeps running during menu tracking, live resize, and
/// scrolling). CEF asks for work through `OnScheduleMessagePumpWork`, which
/// may arrive on any thread; the request moves to the main run loop and
/// resets the timer's fire date.
///
/// The timer is owned and invalidated by `stop()`; there is no `asyncAfter`.
final class CEFMessagePump {
    private let work: () -> Void
    private let liveBrowsers: () -> Int
    private let timer: any CEFPumpTimer
    private let clock: () -> TimeInterval
    private var isRunning = false
    private var isWorking = false
    private var rescheduledDuringWork = false
    private(set) var stats = CEFPumpStats()

    /// `clock` is monotonic seconds (tests inject one).
    init(
        work: @escaping () -> Void,
        liveBrowsers: @escaping () -> Int = { 1 },
        timer: any CEFPumpTimer = CEFRunLoopPumpTimer(),
        clock: @escaping () -> TimeInterval = CEFMessagePump.uptime
    ) {
        self.work = work
        self.liveBrowsers = liveBrowsers
        self.timer = timer
        self.clock = clock
    }

    nonisolated static func uptime() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer.onFire = { [weak self] in self?.fire() }
        schedule(after: 0)
    }

    func stop() {
        isRunning = false
        timer.invalidate()
    }

    /// Main thread: run the pump after `delay` seconds (0 = on the next
    /// run loop pass).
    func schedule(after delay: TimeInterval) {
        guard isRunning else { return }
        if isWorking { rescheduledDuringWork = true }
        timer.arm(after: delay, tolerance: 0)
    }

    /// Main thread: a CEF `OnScheduleMessagePumpWork(delay_ms)` request.
    func request(milliseconds: Int64) {
        if milliseconds <= 0 { stats.immediateRequests += 1 } else { stats.delayedRequests += 1 }
        schedule(after: CEFPumpPolicy.delay(forRequestedMilliseconds: milliseconds))
    }

    /// Runs one pump iteration now (quit path drains without the timer).
    func pumpNow() {
        fire()
    }

    private func fire() {
        // CefDoMessageLoopWork can re-enter through nested run loops (menus,
        // modal panels). A nested fire only reschedules.
        guard !isWorking else {
            stats.reentrantFires += 1
            schedule(after: CEFPumpPolicy.maxDelay)
            return
        }
        isWorking = true
        rescheduledDuringWork = false
        let started = clock()
        work()
        let elapsed = clock() - started
        stats.workRuns += 1
        stats.workSeconds += elapsed
        if elapsed >= 0.01 { stats.longWorkRuns += 1 }
        isWorking = false
        if !rescheduledDuringWork {
            let fallback = CEFPumpPolicy.fallback(liveBrowsers: liveBrowsers())
            stats.fallbackInterval = fallback
            schedule(after: fallback)
        }
    }
}

/// C entry for `OnScheduleMessagePumpWork`. `ctx` is the unretained
/// `CEFRuntime`, which lives for the rest of the process once started.
let cefScheduleCallback: CEFShimLibrary.ScheduleFn = { context, delayMilliseconds in
    guard let context else { return }
    let address = UInt(bitPattern: context)
    let deliver: @Sendable () -> Void = {
        MainActor.assumeIsolated {
            CEFRuntime.from(address)?.pump?.request(milliseconds: delayMilliseconds)
        }
    }
    if Thread.isMainThread {
        deliver()
    } else {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, deliver)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
