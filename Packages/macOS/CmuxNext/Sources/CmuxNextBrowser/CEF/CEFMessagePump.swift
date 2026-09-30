import CoreFoundation
import Foundation

/// Drives `CefDoMessageLoopWork` from one `CFRunLoopTimer` on the main run
/// loop in common modes (so it keeps running during menu tracking, live
/// resize, and scrolling). CEF asks for work through
/// `OnScheduleMessagePumpWork`, which may arrive on any thread; the request
/// moves to the main run loop and resets the timer's fire date.
///
/// The timer is owned and invalidated by `stop()`; there is no `asyncAfter`.
final class CEFMessagePump {
    private let work: () -> Void
    private let liveBrowsers: () -> Int
    private var timer: CFRunLoopTimer?
    private var isWorking = false
    private var rescheduledDuringWork = false
    private(set) var stats = CEFPumpStats()

    init(work: @escaping () -> Void, liveBrowsers: @escaping () -> Int) {
        self.work = work
        self.liveBrowsers = liveBrowsers
    }

    func start() {
        guard timer == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, .greatestFiniteMagnitude, 1.0e10, 0, 0
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
        self.timer = timer
        schedule(after: 0)
    }

    func stop() {
        if let timer { CFRunLoopTimerInvalidate(timer) }
        timer = nil
    }

    /// Main thread: run the pump after `delay` seconds (0 = on the next
    /// run loop pass).
    func schedule(after delay: TimeInterval) {
        guard let timer else { return }
        if isWorking { rescheduledDuringWork = true }
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + delay)
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
        let started = DispatchTime.now().uptimeNanoseconds
        work()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
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
