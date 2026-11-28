import Foundation
import os

/// A quit's one answer to AppKit's terminateLater wait, bounded. `applicationShouldTerminate` answers
/// `.terminateLater` and AppKit spins a nested run loop (`-[NSApplication _shouldTerminate]`, modal
/// panel mode) until `reply(toApplicationShouldTerminate:)`. The quit's reply comes from a main-actor
/// Task. When `NSApp.terminate` was called from inside a main-queue job (a main-actor Task, a
/// `DispatchQueue.main` block), that job cannot return while the nested loop spins and the main
/// queue is serial: the Task never runs, nothing replies, and the app never quits. A relaunch, keep
/// sessions, hung a NIGHTLY that way (2267 of 2267 main-thread samples in `_shouldTerminate`'s
/// `nextEventMatchingMask` under `completeTaskWithClosure`).
///
/// Every quit asks through `NSApplication.terminateFromRunLoop` (a run-loop callout, never a
/// main-queue job; `TerminateCallSiteTests` keeps it so). This watchdog bounds any path that still
/// does not, and any reply that never comes: a one-shot run-loop timer in the common modes (which
/// include the modal panel mode AppKit waits in) needs no main-queue turn, and sends Quit `limit`
/// after it started unless the quit replied first. It is held while the person answers. Whoever
/// sends first (the quit or the watchdog) is the one reply AppKit gets.
@MainActor
public final class QuitReplyWatchdog {
    /// A keep quit ends 4 s after it is decided (`QuitDeadline.keepQuitLimit`); no quit needs this long
    /// between its start (or the person's answer) and its reply.
    public static let limit: Duration = .seconds(10)

    private let limit: Duration
    private let reply: @MainActor (Bool) -> Void
    private var timer: Timer?
    /// The reply went (from the quit or the watchdog).
    public private(set) var replied = false
    /// The watchdog sent it (the quit's own reply never came in time).
    public private(set) var fired = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")

    /// - Parameters:
    ///   - limit: How long the quit may go without replying.
    ///   - reply: Answers AppKit (whether to quit); runs once, on the main thread.
    public init(limit: Duration = QuitReplyWatchdog.limit, reply: @escaping @MainActor (Bool) -> Void) {
        self.limit = limit
        self.reply = reply
    }

    /// A watchdog already counting (``start()``).
    public static func started(limit: Duration = QuitReplyWatchdog.limit, reply: @escaping @MainActor (Bool) -> Void) -> QuitReplyWatchdog {
        let watchdog = QuitReplyWatchdog(limit: limit, reply: reply)
        watchdog.start()
        return watchdog
    }

    /// Whether the watchdog is counting.
    public var isArmed: Bool { timer != nil }

    private var seconds: Double { Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18 }

    /// Starts counting `limit` from now (again after ``hold()``). Never once the reply went.
    public func start() {
        guard !replied else { return }
        timer?.invalidate()
        // wakeup-allow: one-shot bound on a quit's reply, armed only while AppKit waits for that reply.
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            // main-proof: a timer on the main run loop fires on the main thread.
            MainActor.assumeIsolated { self?.fire() }
        }
        // The common modes: AppKit's terminateLater wait runs the loop in the modal panel mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops counting while the quit waits on the person; ``start()`` counts again.
    public func hold() {
        timer?.invalidate()
        timer = nil
    }

    /// Runs `body` held (the person answers in it), then counts again from its end.
    public func holding<T>(_ body: @MainActor () async -> T) async -> T {
        hold()
        defer { start() }
        return await body()
    }

    /// The quit's reply; only the first one (the quit's or the watchdog's) reaches AppKit.
    public func send(_ quits: Bool) {
        hold()
        guard !replied else { return }
        replied = true
        reply(quits)
    }

    private func fire() {
        guard timer != nil, !replied else { return }
        timer = nil
        fired = true
        logger.fault("quit reply watchdog: no reply \(self.seconds, privacy: .public) s after the quit began; replying Quit (terminate called inside a main-queue job?)")
        send(true)
    }
}
