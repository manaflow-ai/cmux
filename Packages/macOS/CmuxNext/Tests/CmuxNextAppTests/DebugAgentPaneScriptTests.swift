@testable import CmuxNextApp
import Foundation
import Testing
import WebKit

/// After a relaunch the restore journey's first `debug.agent_pane chat_state` took 60 s on every
/// run ("chat page connected 61.2 s after it was shown"): the call waited for the page's debug
/// hook by awaiting animation frames, which a page not drawing yet never gets, until the 60 s
/// deadline. A page without the hook must answer that it has none, within a few seconds.
@MainActor
@Suite struct DebugAgentPaneScriptTests {
    @Test func aPageThatDrawsNoFrameAnswersWithoutItsHookInSeconds() async throws {
        // In no window: WebKit runs its scripts and timers but draws no frame.
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let loaded = LoadWait()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("<!doctype html><title>no hook</title><p>not the chat page</p>", baseURL: nil)
        try await loaded.finished()

        let started = ContinuousClock.now
        let call = Call()
        let running = Task { @MainActor in
            call.answer = try? await webView.callAsyncJavaScript(DebugAgentPane.script, arguments: ["fn": "chatState", "args": [Any]()],
                                                                 in: nil, contentWorld: .page) as? String
            call.done = true
        }
        // A hung call must fail the test, not hang it: wait at most 10 s.
        let deadline = started + .seconds(10)
        while !call.done, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let took = ContinuousClock.now - started
        running.cancel()
        #expect(call.done, "the call did not answer within 10 s")
        #expect(call.answer?.contains("has no cmuxAcpmuxDebug.chatState") == true, "answer: \(String(describing: call.answer))")
        #expect(took < .seconds(7), "a page without the hook held the call \(took)")
    }

    @MainActor private final class Call {
        var answer: String?
        var done = false
    }

    /// The test page's load end.
    private final class LoadWait: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, any Error>?
        private var done = false

        func finished() async throws {
            if done { return }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
