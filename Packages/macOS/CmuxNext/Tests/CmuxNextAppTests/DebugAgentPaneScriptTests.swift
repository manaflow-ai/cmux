@testable import CmuxNextApp
import Foundation
import Testing
import WebKit

/// After a relaunch the restore journey's first `debug.agent_pane chat_state` took 60 s on every
/// run ("chat page connected 61.2 s after it was shown"): the call waited for the page's debug
/// hook by awaiting animation frames, which a page not drawing yet never gets, until the 60 s
/// deadline. A page without the hook must answer that it has none, within a few seconds.
///
/// The few seconds are the page's: its clock times the script, so the time other tests hold the
/// main actor before the answer is delivered does not count (a parallel run of the target held
/// it 8.3 s, 7.6 s and 33.6 s at width 4 and 6, where the test's own clock failed it).
/// A call that never answers (the frame wait) ends the test at its time limit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DebugAgentPaneScriptTests {
    @Test func aPageThatDrawsNoFrameAnswersWithoutItsHookInSeconds() async throws {
        // In no window: WebKit runs its scripts and timers but draws no frame.
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let loaded = LoadWait()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("<!doctype html><title>no hook</title><p>not the chat page</p>", baseURL: nil)
        try await loaded.finished()

        let answer = try? await webView.callAsyncJavaScript(Self.timed, arguments: ["fn": "chatState", "args": [Any]()],
                                                            in: nil, contentWorld: .page) as? String
        let timed = try answer.map { try JSONDecoder().decode(Timed.self, from: Data($0.utf8)) }
        #expect(timed != nil, "the call did not answer: \(String(describing: answer))")
        #expect(timed?.answer.contains("has no cmuxAcpmuxDebug.chatState") == true, "answer: \(String(describing: answer))")
        let took = timed.map { Duration.milliseconds($0.ms) }
        #expect(took.map { $0 < .seconds(7) } == true, "a page without the hook held the call \(String(describing: took)) on its own clock")
    }

    /// `DebugAgentPane.script` as it runs, with the page's own time for it (`performance.now`).
    private static var timed: String {
        """
        const started = performance.now();
        const answer = await (async () => {
        \(DebugAgentPane.script)
        })();
        return JSON.stringify({ answer, ms: performance.now() - started });
        """
    }

    private struct Timed: Decodable {
        var answer: String
        var ms: Double
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
