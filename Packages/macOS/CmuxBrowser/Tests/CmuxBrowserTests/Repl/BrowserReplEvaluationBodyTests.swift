import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// `frame.evaluate` takes the agent's function source as text, and the driver
/// runs it after the frame gate's document check in one script. Source that
/// closes the expression it is put in would run before that check (WebKit
/// evaluates the whole script, then calls the function it ends in), so it
/// could act in a frame the domain policy blocks.
@MainActor
@Suite("Evaluation body", .serialized)
struct BrowserReplEvaluationBodyTests {
    /// Closes the call, the try block, the gate's scope and the script's
    /// function, runs a statement of its own, and opens a function that
    /// takes the rest of the body.
    static let breakout = """
        0)} catch (e) {} }) } ), document.documentElement.setAttribute("data-ran", "1"), (async function () { (async () => { try { (0
        """

    @Test("Source that closes its expression does not run in a frame the policy blocks")
    func breakoutSourceDoesNotRunInABlockedFrame() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let child = try #require(page.frame(path: "/child"))
        _ = try await gate.callAsyncJavaScript("return 1", arguments: [:], in: page.webView, frame: child, contentWorld: .page)
        _ = try await page.run("document.getElementById('a').src = 'cmux-test://blocked.test/moved'; return true", in: page.main)
        _ = try await FramePage.settle(page.webView) { frames in
            frames.contains { $0.url == "cmux-test://blocked.test/moved" }
        }
        let error = await BrowserReplFrameGateTests.error {
            let body = try BrowserReplEvaluationBody(source: Self.breakout, requiresAgent: false, elementsExpression: "[]")
            return try await gate.callAsyncJavaScript(
                body.text, arguments: ["__args": [Any](), "__handles": [String]()],
                in: page.webView, frame: child, contentWorld: .page
            )
        }
        #expect(error != nil, "the breakout source's script was run")
        let ran = try await page.run("return document.documentElement.getAttribute('data-ran')", in: child)
        #expect(ran as? String == nil, "the breakout source ran in the blocked document")
    }
}
