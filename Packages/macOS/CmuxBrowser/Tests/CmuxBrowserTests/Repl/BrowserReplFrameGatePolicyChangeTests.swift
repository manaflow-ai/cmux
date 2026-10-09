import AppKit
import WebKit
import Testing

@testable import CmuxBrowser

/// A session that narrows its domain policy while a frame read or an input
/// of several native events is in flight gets nothing more from a frame the
/// new policy blocks: the read's result is judged again under the new
/// policy before it is handed on, and the input's next native step is
/// refused (docs/browser-repl/driver-protocol.md, Guards).
@MainActor
@Suite("Frame gate policy change", .serialized)
struct BrowserReplFrameGatePolicyChangeTests {
    /// A session without a policy sets its first one while a read is in
    /// flight (a read under a policy is judged again after it runs anyway).
    @Test func aReadInFlightWhenThePolicyNarrowsReturnsNothingFromTheNewlyBlockedFrame() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGate(world: BrowserReplFrameGateTests.world)
        #expect(!gate.isActive(in: page.webView))
        let frame = try #require(page.frame(host: "blocked.test"))
        let webView = page.webView
        let read = Task { @MainActor in
            await BrowserReplFrameGateTests.error {
                try await gate.callAsyncJavaScript(
                    "await new Promise(resolve => { window.__cmuxPolicyGo = resolve }); return document.body.innerText",
                    arguments: [:], in: webView, frame: frame, contentWorld: .page
                )
            }
        }
        // The read is suspended in the frame, waiting for the go signal.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while try await page.run("return typeof window.__cmuxPolicyGo", in: frame) as? String != "function" {
            try #require(ContinuousClock.now < deadline, "the read never started in the frame")
            try await Task.sleep(for: .milliseconds(20))
        }
        gate.policy = BrowserReplFrameGateTests.gate().policy
        _ = try await page.run("window.__cmuxPolicyGo(); return true", in: frame)
        let error = await read.value
        #expect(error?.code == "blocked", "a read that finished after the policy blocked its frame was handed on: \(String(describing: error))")
    }

    /// The gate's checks before a script await WebKit (the frame tree its
    /// reach check reads); the user can move the tab out of the session's
    /// workspace, or the session can set its policy, meanwhile. The script
    /// is then never dispatched: its side effects would come before the
    /// check that only discards its result.
    @Test func aScriptIsNotDispatchedWhenTheTabMovedWhileTheGateCheckedIt() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let frame = try #require(page.frame(host: "allowed.test"))
        let own = UUID()
        let tabID = UUID()
        let place = WorkspaceBox(own)
        gate.scope = { _ in
            .init(sessionID: "s", fileRoots: nil, tab: BrowserReplTabFacts(id: tabID, attachedSessionIDs: ["s"], workspaceID: place.id), workspaceID: own)
        }
        gate.frameTree = { webView in
            // The user moves the tab while the gate reads the tree.
            place.id = UUID()
            return await BrowserReplFrame.readTree(of: webView)
        }
        let error = await BrowserReplFrameGateTests.error {
            try await gate.callAsyncJavaScript("window.__cmuxDispatched = true; return 1", arguments: [:], in: page.webView, frame: frame, contentWorld: .page)
        }
        #expect(error?.code == "denied", "\(String(describing: error))")
        #expect(try await page.run("return typeof window.__cmuxDispatched", in: frame) as? String == "undefined", "the script ran in a tab the session no longer may use")
    }

    @Test func aScriptIsNotDispatchedWhenThePolicyChangedWhileTheGateCheckedIt() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate()
        let frame = try #require(page.frame(host: "allowed.test"))
        gate.frameTree = { webView in
            // The session narrows its policy while the gate reads the tree.
            gate.policy = BrowserReplFrameGateTests.gate(prohibiting: "cmux-test://allowed.test").policy
            return await BrowserReplFrame.readTree(of: webView)
        }
        let error = await BrowserReplFrameGateTests.error {
            try await gate.callAsyncJavaScript("window.__cmuxDispatched = true; return 1", arguments: [:], in: page.webView, frame: frame, contentWorld: .page)
        }
        #expect(error != nil, "a script checked under the old policy was handed on")
        #expect(try await page.run("return typeof window.__cmuxDispatched", in: frame) as? String == "undefined", "the script ran after the policy blocked its frame")
    }

    @Test func anInputInFlightWhenThePolicyNarrowsSendsNoFurtherStep() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate(prohibiting: "cmux-test://other.test")
        var before: BrowserReplDriverError?
        var after: BrowserReplDriverError?
        _ = await BrowserReplFrameGateTests.error {
            try await gate.guardingInput(in: page.webView, frames: { page.frames }, checkFocusAfter: false) {
                before = await BrowserReplFrameGateTests.error { try gate.checkTab(in: page.webView) }
                gate.policy = BrowserReplFrameGateTests.gate().policy
                after = await BrowserReplFrameGateTests.error { try gate.checkTab(in: page.webView) }
                return nil
            }
        }
        #expect(before == nil, "the step before the policy changed was refused: \(String(describing: before))")
        #expect(after?.code == "stale", "a step of the input ran under the policy it started with: \(String(describing: after))")
    }

    /// An input that starts after the change is judged by the new policy
    /// alone, so the change refuses only the input already in flight.
    @Test func anInputThatStartsAfterThePolicyChangedIsNotRefusedForIt() async throws {
        let page = try await FramePage.load()
        let gate = BrowserReplFrameGateTests.gate(prohibiting: "cmux-test://other.test")
        gate.policy = BrowserReplFrameGateTests.gate(prohibiting: "cmux-test://another.test").policy
        var step: BrowserReplDriverError?
        _ = try await gate.guardingInput(in: page.webView, frames: { page.frames }, checkFocusAfter: false) {
            step = await BrowserReplFrameGateTests.error { try gate.checkTab(in: page.webView) }
            return true
        }
        #expect(step == nil, "an input that started under the current policy was refused: \(String(describing: step))")
    }
}

@MainActor
private final class WorkspaceBox {
    var id: UUID
    init(_ id: UUID) { self.id = id }
}
