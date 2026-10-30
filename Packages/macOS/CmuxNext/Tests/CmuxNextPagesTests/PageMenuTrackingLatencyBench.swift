import Foundation
import Testing

/// What a context menu's tracking loop does to the main queue, measured in-process: a stand-in
/// menu (a nested run loop in the event-tracking mode, for `open` seconds, as `NSMenu.popUp`
/// runs) opens either inside a main-queue job (where base opened the Chromium page's menu and the
/// agent chat's More and fork menus: a CEF pump pass, a main-actor Task) or from a main run-loop
/// callout (``MainRunLoopBlock``, where they open now). Work queued on the main queue while it is
/// open (page replies, transcript updates, Chromium events) runs during the menu from a callout;
/// inside a job it all waits until the menu closes, and the closing click waits behind it (Leo,
/// 2026-10-29: "clicking out of a fucking context menu is sometimes slow as fucking balls").
///
/// The test runs off the main actor so the main thread is free to run its own run loop.
@Suite(.serialized) struct PageMenuTrackingLatencyBench {
    enum Opener { case mainQueueJob, runLoopCallout }

    /// The longest wait, in ms, of main-queue jobs queued every 5 ms while the menu is open.
    static func worstWait(_ opener: Opener, open: TimeInterval = 0.4) -> Double {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var worst = 0.0
        var menuClosed = false
        let menu = {
            let tracking = CFRunLoopMode(rawValue: "NSEventTrackingRunLoopMode" as CFString)
            let main = CFRunLoopGetMain()
            CFRunLoopAddCommonMode(main, tracking)
            let end = CFAbsoluteTimeGetCurrent() + open
            while CFAbsoluteTimeGetCurrent() < end {
                CFRunLoopPerformBlock(main, tracking.rawValue) {}
                _ = CFRunLoopRunInMode(tracking, 0.005, false)
            }
            lock.withLock { menuClosed = true }
        }
        switch opener {
        case .mainQueueJob:
            DispatchQueue.main.async(execute: menu)
        case .runLoopCallout:
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, menu)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        // Main-queue work arriving while the menu is open.
        let started = CFAbsoluteTimeGetCurrent()
        let group = DispatchGroup()
        while CFAbsoluteTimeGetCurrent() - started < open * 0.75 {
            let queued = CFAbsoluteTimeGetCurrent()
            group.enter()
            DispatchQueue.main.async {
                let waited = (CFAbsoluteTimeGetCurrent() - queued) * 1000
                lock.withLock { worst = max(worst, waited) }
                group.leave()
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        group.notify(queue: .global()) { done.signal() }
        _ = done.wait(timeout: .now() + 30)
        _ = lock.withLock { menuClosed }
        return lock.withLock { worst }
    }

    @Test func mainQueueWorkRunsWhileAMenuOpenedFromARunLoopCalloutTracks() {
        _ = Self.worstWait(.runLoopCallout, open: 0.05) // warm the main run loop
        let inJob = (0..<5).map { _ in Self.worstWait(.mainQueueJob) }.sorted()[2]
        let fromCallout = (0..<5).map { _ in Self.worstWait(.runLoopCallout) }.sorted()[2]
        print(String(format: "page-menu-tracking-bench: worst main-queue wait while a 400 ms menu is open: in a main-queue job %.1f ms, from a run-loop callout %.1f ms", inJob, fromCallout))
        #expect(inJob > 200, "a menu tracking inside a main-queue job should hold the main queue")
        #expect(fromCallout < 100, "main-queue work waited \(fromCallout) ms while the menu tracked from a callout")
    }
}
