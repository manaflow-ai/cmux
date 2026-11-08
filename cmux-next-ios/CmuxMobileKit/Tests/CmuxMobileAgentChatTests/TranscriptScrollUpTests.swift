#if os(iOS)
import Darwin
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// AgentIncomingCaptureUITests on feat-cmux-next: scrolling the offline DEBUG chat's history up
/// (MockAgentSession with history, the `disclosure-chat` demo) froze the app when the turns other
/// agents' messages started came near the screen (AgentIncomingCardLayoutTests has the cause). The
/// real transcript controller in a window is scrolled up a page at a time; a watchdog thread ends
/// the run when one step takes longer than a bounded wait.
@MainActor
@Suite(.serialized) struct TranscriptScrollUpTests {
    @Test func scrollingUpThroughTheHistoryKeepsTheMainThreadFree() async throws {
        let summary = AgentSessionSummary(id: "s", name: "Refactor transport layer", harness: "claude", agentName: "Claude",
                                          cwd: "~/cmux", workspaceTitle: "cmux", macName: "Mac")
        let mock = MockAgentSession(summary: summary, richFirstTurn: false, history: true, sleep: { _ in await Task.yield() })
        let store = AgentChatStore(source: mock)
        for _ in 0 ..< 500 where store.turns.isEmpty { await Task.yield() }
        try #require(!store.turns.isEmpty, "the history replayed")
        let surface = AgentChatSurface()
        let controller = ChatTranscriptController(placement: .owned, surface: surface, store: store,
                                                  empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil)
        controller.reducesMotion = { false }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let scroll = try #require(controller.view.subviews.lazy.compactMap { $0 as? ChatTranscriptCollectionView }.first)

        func frame() async {
            try? await Task.sleep(for: .milliseconds(16))
            controller.view.layoutIfNeeded()
            CATransaction.flush()
        }
        for _ in 0 ..< 60 { await frame() }
        try #require(scroll.contentSize.height > scroll.bounds.height, "content measured \(scroll.contentSize.height)")

        let watchdog = MainThreadWatchdog(limit: 10)
        defer { watchdog.stop() }
        // A page at a time from the newest row to the top, as the UI test's drags go, with the
        // list's own drag callbacks around each step.
        var steps = 0
        while scroll.contentOffset.y > -scroll.adjustedContentInset.top + 1, steps < 80 {
            steps += 1
            watchdog.beat("step \(steps) at \(scroll.contentOffset.y)")
            controller.scrollViewWillBeginDragging(scroll)
            for _ in 0 ..< 8 {
                let y = max(-scroll.adjustedContentInset.top, scroll.contentOffset.y - 44)
                scroll.contentOffset = CGPoint(x: 0, y: y)
                await frame()
            }
            controller.scrollViewDidEndDragging(scroll, willDecelerate: false)
            for _ in 0 ..< 10 { await frame() }
        }
        watchdog.beat("done")
        #expect(steps > 1, "the history is taller than a page: \(steps) steps")
    }
}

/// Fails the test run with the main thread's stack (to stderr, so the run's console keeps it)
/// when the main thread has not called `beat` for `limit` seconds: a hang ends the run in
/// seconds with its cause instead of at the runner's timeout with none.
final class MainThreadWatchdog: @unchecked Sendable {
    // concurrency-allow: written by the main thread's beat and read by the watchdog thread under `lock`.
    private let lock = NSLock()
    private var last = Date()
    private var label = "start"
    private var code: Int32 = 86
    private var running = true

    init(limit: TimeInterval, exitCode: Int32 = 86) {
        code = exitCode
        MainThreadWatchdog.main = pthread_self()
        signal(SIGUSR2) { _ in
            let stack = Thread.callStackSymbols.joined(separator: "\n")
            fputs("MainThreadWatchdog: main thread stack\n\(stack)\n", stderr)
        }
        let thread = Thread { [self] in
            var dumps = 0
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                lock.lock()
                let (running, last, label, code) = (self.running, self.last, self.label, self.code)
                lock.unlock()
                guard running else { return }
                let stalled = Date().timeIntervalSince(last)
                guard stalled > limit, let main = MainThreadWatchdog.main else { continue }
                fputs("MainThreadWatchdog: the main thread is stuck \(Int(stalled)) s after \(label)\n", stderr)
                pthread_kill(main, SIGUSR2)
                dumps += 1
                Thread.sleep(forTimeInterval: 2)
                if dumps >= 3 {
                    fputs("MainThreadWatchdog: ending the run\n", stderr)
                    exit(code)
                }
            }
        }
        thread.start()
    }

    // concurrency-allow: set once on the main thread before the watchdog thread starts.
    nonisolated(unsafe) static var main: pthread_t?

    func beat(_ label: String, code: Int32? = nil) {
        lock.lock()
        last = Date()
        self.label = label
        if let code { self.code = code }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }
}
#endif
