import CmuxNextBrowser
import CmuxNextBrowserAutomation
@testable import CmuxNextBrowserHost
import CmuxNextWakeups
import Foundation
import Testing

/// An agent's capture of a tab nobody sees votes on the tab's node, so the tab
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

    // MARK: The CDP relay (CEF tabs)

    /// `Page.captureScreenshot` votes before the send; the write queue reads the reply's id, and the
    /// automation task it posts ends the vote. A reply to another command keeps it.
    @Test func aRelayedScreenshotHoldsTheTabsVoteUntilItsReply() async throws {
        let capture = StandInCapture()
        let fixture = try await Self.attachedRelay(capture)
        let evaluate = try await Self.relay(fixture, #"{"id":10,"method":"Runtime.evaluate","params":{"expression":"1"}}"#)
        let screenshot = try await Self.relay(fixture, #"{"id":11,"method":"Page.captureScreenshot"}"#)
        #expect(capture.node.isCaptured && capture.node.wantsFrames, "the screenshot of a hidden tab took no vote")
        #expect(capture.node.effective == .hidden, "the vote showed the page")
        #expect(capture.reasons == ["agent.screenshot"])

        fixture.sources.fromBrowser?(#"{"id":\#(evaluate),"result":{"result":{"type":"number","value":1}}}"#)
        try await Self.expectReply(fixture, hostID: 10)
        Self.settle(fixture, passes: 4)
        #expect(capture.node.isCaptured, "another command's reply ended the screenshot's vote")

        fixture.sources.fromBrowser?(#"{"id":\#(screenshot),"result":{"data":"AAAA"}}"#)
        try await Self.expectReply(fixture, hostID: 11)
        Self.settle(fixture) { !capture.node.isCaptured }
        #expect(!capture.node.isCaptured, "the answered screenshot kept its vote")
        #expect(capture.node.captureReasons.isEmpty)
        await fixture.close()
    }

    /// `Page.startScreencast` holds one vote, through its own reply and a repeated start, until
    /// `Page.stopScreencast`.
    @Test func aScreencastHoldsOneVoteUntilItStops() async throws {
        let capture = StandInCapture()
        let fixture = try await Self.attachedRelay(capture)
        let start = try await Self.relay(fixture, #"{"id":20,"method":"Page.startScreencast","params":{"format":"jpeg"}}"#)
        #expect(capture.node.isCaptured && capture.node.effective == .hidden)
        fixture.sources.fromBrowser?(#"{"id":\#(start),"result":{}}"#)
        try await Self.expectReply(fixture, hostID: 20)
        Self.settle(fixture, passes: 4)
        #expect(capture.node.isCaptured, "the start's reply ended the screencast's vote")
        _ = try await Self.relay(fixture, #"{"id":21,"method":"Page.startScreencast"}"#)
        #expect(capture.node.captureReasons == ["agent.screencast"], "a repeated start took a second vote")
        _ = try await Self.relay(fixture, #"{"id":22,"method":"Page.stopScreencast"}"#)
        #expect(!capture.node.isCaptured, "the stopped screencast kept its vote")
        #expect(capture.node.captureReasons.isEmpty)
        await fixture.close()
    }

    /// `cdp.detach` ends every capture the relay holds: a screenshot without its reply and a screencast.
    @Test func aDetachReleasesEveryCapture() async throws {
        let capture = StandInCapture()
        let fixture = try await Self.attachedRelay(capture)
        _ = try await Self.relay(fixture, #"{"id":30,"method":"Page.captureScreenshot"}"#)
        _ = try await Self.relay(fixture, #"{"id":31,"method":"Page.startScreencast"}"#)
        #expect(capture.node.captureReasons == ["agent.screenshot", "agent.screencast"])
        await fixture.host.send(.cdpDetach(targetID: "tab-1"))
        await fixture.turns.runNext()
        #expect(!capture.node.isCaptured, "the detached relay kept a vote")
        #expect(capture.node.captureReasons.isEmpty)
        await fixture.close()
    }

    /// The tab's browser going away under the relay ends every capture it holds.
    @Test func aBrowserCloseReleasesEveryCapture() async throws {
        let capture = StandInCapture()
        let fixture = try await Self.attachedRelay(capture)
        _ = try await Self.relay(fixture, #"{"id":40,"method":"Page.captureScreenshot"}"#)
        _ = try await Self.relay(fixture, #"{"id":41,"method":"Page.startScreencast"}"#)
        #expect(capture.node.captureReasons == ["agent.screenshot", "agent.screencast"])
        fixture.sources.closedByBrowser?()
        #expect(!capture.node.isCaptured, "the closed relay kept a vote")
        #expect(capture.node.captureReasons.isEmpty)
        _ = try await fixture.host.next { if case .event("tab.relay.closed", _) = $0 { true } else { false } }
        await fixture.close()
    }

    /// A screenshot the browser never got ends its vote at once, and the host reads a CDP error.
    @Test func aScreenshotThatWasNotSentEndsItsVote() async throws {
        let capture = StandInCapture()
        let fixture = try await Self.attachedRelay(capture)
        fixture.sources.sendResult = .noBrowser
        await fixture.host.send(.cdp(targetID: "tab-1", message: #"{"id":50,"method":"Page.captureScreenshot"}"#))
        await fixture.turns.runNext()
        #expect(capture.reasons == ["agent.screenshot"], "the screenshot took no vote before the send")
        #expect(!capture.node.isCaptured, "the unsent screenshot kept its vote")
        let reply = try await Self.expectReply(fixture, hostID: 50)
        #expect(reply.contains(#""error""#))
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

extension BrowserHostProviderCaptureTests {
    /// A provider whose host attached the relay of hidden CEF tab `tab-1`, and the relay started.
    static func attachedRelay(_ capture: any ProviderCaptureVoting) async throws -> ProviderFixture {
        let fixture = try ProviderFixture(capture: capture)
        fixture.sources.relayReady = true
        fixture.sources.list.tabs = [ProviderTab(targetID: "tab-1", engine: .cef, workspace: "w", profile: "p",
                                                 url: "https://example.com/", title: "Example", visible: false)]
        try await fixture.connect()
        await fixture.host.send(.cdpAttach(targetID: "tab-1"))
        await fixture.turns.runNext()
        await fixture.sources.started()
        return fixture
    }

    /// Sends one host command through the relay; returns the raw id the browser got it with.
    static func relay(_ fixture: ProviderFixture, _ message: String) async throws -> Int {
        let sent = fixture.sources.relayed.count
        await fixture.host.send(.cdp(targetID: "tab-1", message: message))
        await fixture.turns.runNext()
        #expect(fixture.sources.relayed.count == sent + 1, "the command did not reach the browser")
        return try #require(fixture.sources.relayed.last.flatMap { CDPRawIDMap.topLevelID(in: $0) })
    }

    /// Waits for the host's reply to its command `hostID` on `tab-1`; returns the reply.
    @discardableResult
    static func expectReply(_ fixture: ProviderFixture, hostID: Int) async throws -> String {
        let frame = try await fixture.host.next { frame in
            guard case .cdp("tab-1", let message) = frame else { return false }
            return CDPRawIDMap.topLevelID(in: message) == hostID
        }
        guard case .cdp(_, let message) = frame else { return "" }
        return message
    }

    /// Runs the scheduler's held turns and the main run loop, where a task posted off main arrives,
    /// until `done`, for at most `passes` passes and 5 s.
    static func settle(_ fixture: ProviderFixture, passes: Int = .max, until done: () -> Bool = { false }) {
        let end = Date(timeIntervalSinceNow: 5)
        var pass = 0
        while !done(), pass < passes, Date() < end {
            pass += 1
            _ = fixture.turns.runQueued()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        _ = fixture.turns.runQueued()
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
