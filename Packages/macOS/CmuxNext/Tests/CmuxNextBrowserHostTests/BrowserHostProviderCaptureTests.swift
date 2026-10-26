import CmuxNextBrowser
import CmuxNextBrowserAutomation
@testable import CmuxNextBrowserHost
import CmuxNextWakeups
import Foundation
import Testing

/// p06-scheduler-211: an agent's capture of a tab nobody sees votes on the tab's node, so the tab
/// renders for it, and the vote ends with the capture (Chromium's DevTools page handler holds a
/// `stay_hidden` capturer count for `Page.captureScreenshot` and `Page.startScreencast`).
@MainActor @Suite(.timeLimit(.minutes(1))) struct BrowserHostProviderCaptureTests {
    @Test func aDriverScreenshotHoldsTheTabsVoteUntilItAnswers() async throws {
        let capture = StandInCapture()
        let driver = HeldDriver()
        let fixture = try ProviderFixture(driver: driver, capture: capture)
        fixture.sources.list.tabs = [ProviderTab(targetID: "tab-1", engine: .webkit, workspace: "w", profile: "p",
                                                 url: "https://example.com/", title: "Example", visible: false)]
        try await fixture.connect()
        await fixture.host.send(.call(id: 3, method: "tab.screenshot", params: .object(["targetId": .string("tab-1")])))
        await fixture.turns.runNext()
        await driver.called()
        #expect(capture.node.isCaptured && capture.node.wantsFrames, "the screenshot of a hidden tab took no vote")
        #expect(capture.node.effective == .hidden, "the vote showed the page")
        #expect(capture.reasons == ["agent.screenshot"])
        driver.answer()
        _ = try await fixture.host.next { if case .result(3, _, _) = $0 { true } else { false } }
        #expect(!capture.node.isCaptured, "the answered screenshot kept its vote")
        await fixture.close()
    }

    @Test func otherDriverCallsTakeNoVote() async throws {
        let capture = StandInCapture()
        let driver = HeldDriver()
        let fixture = try ProviderFixture(driver: driver, capture: capture)
        fixture.sources.list.tabs = [ProviderTab(targetID: "tab-1", engine: .webkit, workspace: "w", profile: "p",
                                                 url: "https://example.com/", title: "Example", visible: false)]
        try await fixture.connect()
        await fixture.host.send(.call(id: 4, method: "tab.info", params: .object(["targetId": .string("tab-1")])))
        await fixture.turns.runNext()
        await driver.called()
        #expect(capture.reasons.isEmpty && !capture.node.isCaptured)
        driver.answer()
        _ = try await fixture.host.next { if case .result(4, _, _) = $0 { true } else { false } }
        await fixture.close()
    }

    @Test func onlyTopLevelCaptureMethodsAreCaptureCommands() {
        #expect(CDPCaptureCommand(command: #"{"id":1,"method":"Page.captureScreenshot","params":{"format":"png"}}"#) == .screenshot)
        #expect(CDPCaptureCommand(command: #"{"id":2,"sessionId":"S","method":"Page.startScreencast"}"#) == .startScreencast)
        #expect(CDPCaptureCommand(command: #"{"id":3,"method":"Page.stopScreencast"}"#) == .stopScreencast)
        #expect(CDPCaptureCommand(command: #"{"id":4,"method":"Page.navigate","params":{"url":"https://example.com"}}"#) == nil)
        let script = #"{"id":5,"method":"Runtime.evaluate","params":{"expression":"'Page.captureScreenshot'"}}"#
        #expect(CDPCaptureCommand(command: script) == nil, "a script that names the method is not a capture")
    }

    @Test func aReplyNamesTheRawIDItAnswers() throws {
        let table = CDPRelayTable()
        let out = try #require(table.outbound(#"{"id":7,"method":"Page.captureScreenshot"}"#))
        let reply = table.inboundReply(#"{"id":\#(out.rawID),"result":{"data":"AAAA"}}"#)
        #expect(reply.rawID == out.rawID)
        #expect(reply.message == #"{"id":7,"result":{"data":"AAAA"}}"#)
        let event = table.inboundReply(#"{"method":"Page.screencastFrame","params":{}}"#)
        #expect(event.rawID == nil && event.message != nil)
    }
}

/// One tab node that captures vote on, with the reasons asked.
@MainActor
private final class StandInCapture: ProviderCaptureVoting {
    let node = VisibilityNode(root: "tab:tab-1", own: .hidden)
    private(set) var reasons: [String] = []

    func captureVote(targetID: String, reason: String) -> VisibilityCaptureVote? {
        guard targetID == "tab-1" else { return nil }
        reasons.append(reason)
        return node.captureVote(reason: reason, stayHidden: true)
    }
}

/// A WebKit driver whose call waits until the test answers it.
@MainActor
private final class HeldDriver: DriverCallHandler {
    let events = AsyncStream<DriverEvent> { _ in }
    private var reply: CheckedContinuation<Void, Never>?
    private var callWaiter: CheckedContinuation<Void, Never>?
    private var callCount = 0

    func call(method: String, params: DriverJSON) async throws(DriverError) -> DriverJSON {
        callCount += 1
        callWaiter?.resume()
        callWaiter = nil
        await withCheckedContinuation { reply = $0 }
        return .object([:])
    }

    /// Waits until the provider called the driver.
    func called() async {
        if callCount == 0 { await withCheckedContinuation { callWaiter = $0 } }
    }

    /// Answers the pending call.
    func answer() {
        reply?.resume()
        reply = nil
    }
}
