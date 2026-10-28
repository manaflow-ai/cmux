import CmuxNextBrowser
import CmuxNextBrowserAutomation
@testable import CmuxNextBrowserHost
import CmuxNextWakeups
import Foundation
import Testing

/// With the Chromium Host's relay link up, the browser host sends `cdp.prepare`; the app
/// makes the tab agent-ready as for its own relay, names the page to the browser host (`tab.relay.direct`)
/// and relays none of its CDP; capture commands the browser host sent to the Chromium Host still vote here.
@MainActor @Suite(.timeLimit(.minutes(1))) struct BrowserHostProviderDirectRelayTests {
    /// The browser host checks the same bytes (cmux-browser-host provider_link/direct_relay_tests.rs,
    /// `RELAY_TEST_VECTOR`): HMAC-SHA256 keyed by "test-secret" of "cmux-chromium-host-relay-v1".
    @Test func theRelayCredentialIsTheBrowserHostsDerivation() {
        let credential = ProviderSecret("test-secret").relayCredential
        #expect(credential.value == "e40644f33ec8afb45205d144cbef8fec286fa012fbb4ecec8da38ae5153cb334")
        #expect(credential != ProviderSecret("test-secret"))
        #expect("\(credential)" == "ProviderSecret(<redacted>)")
    }

    @Test func theRelayLinkCarriesTheDerivedCredentialNeverTheSecret() {
        let credentials = ProviderCredentials(socketPath: "/tmp/bh/browser-host-provider.sock", secret: ProviderSecret("test-secret"),
                                              hostPID: 10, listenerPID: 11)
        let link = BrowserHostProvider.relayLink(credentials, linkID: "L1")
        #expect(link.credential == ProviderSecret("test-secret").relayCredential.value)
        #expect(link.credential != "test-secret")
        #expect(link.socketPath == credentials.socketPath && link.linkID == "L1")
        #expect(link.hostPID == 10 && link.listenerPID == 11)
        #expect(!"\(link)".contains(link.credential), "a description shows the credential")
        let noListener = BrowserHostProvider.relayLink(ProviderCredentials(socketPath: "/s", secret: ProviderSecret("x"), hostPID: 3),
                                                       linkID: "L1")
        #expect(noListener.listenerPID == 0)
    }

    @Test func prepareAndCaptureFramesRoundTrip() throws {
        let frames: [ProviderFrame] = [
            .cdpPrepare(targetID: "tab-1"),
            .cdpCapture(targetID: "tab-1", capture: "screenshot", active: true, id: 1_610_612_736),
            .cdpCapture(targetID: "tab-1", capture: "screencast", active: false, id: nil),
        ]
        for frame in frames {
            let data = try ProviderCodec.encode(frame)
            #expect(try ProviderCodec.decode(Data(data.dropFirst(4))) == frame)
        }
        #expect(BrowserHostProvider.task(for: frames[0])?.owner == "browser-host.cdp.prepare")
        #expect(BrowserHostProvider.task(for: frames[1])?.owner == "browser-host.cdp.capture")
    }

    @Test func aPreparedTabIsNamedToTheBrowserHostAndTheAppRelaysNone() async throws {
        let fixture = try await Self.prepared(direct: CEFAgentDirectTarget(browser: 1_048_576, linkID: "L1"))
        let payload = try await Self.answer(fixture, "tab.relay.direct")
        #expect(payload["targetId"] == .string("tab-1"))
        #expect(payload["browser"] == .number(1_048_576))
        #expect(payload["link"] == .string("L1"))
        #expect(fixture.sources.fromBrowser == nil, "a direct tab started the app's relay")
        // A command that still reaches the app gets a CDP error, never the browser.
        await fixture.host.send(.cdp(targetID: "tab-1", message: #"{"id":5,"method":"Page.enable"}"#))
        await fixture.turns.runNext()
        #expect(fixture.sources.relayed.isEmpty)
        let reply = try await fixture.host.next { if case .cdp("tab-1", _) = $0 { true } else { false } }
        guard case .cdp(_, let message) = reply else { return }
        #expect(message.contains(#""error""#))
        await fixture.close()
    }

    /// A page the Chromium Host cannot relay (in process, no link) is named without a link: the browser host
    /// then relays it through the app.
    @Test func aTabTheHostCannotRelayIsNamedWithoutALink() async throws {
        let fixture = try await Self.prepared(direct: nil)
        let payload = try await Self.answer(fixture, "tab.relay.direct")
        #expect(payload["link"] == nil && payload["browser"] == nil)
        await fixture.close()
    }

    @Test func aPageThatCannotStartFailsThePrepare() async throws {
        let fixture = try await Self.prepared(direct: CEFAgentDirectTarget(browser: 1, linkID: "L1"), ready: false)
        let payload = try await Self.answer(fixture, "tab.relay.failed")
        #expect(payload["targetId"] == .string("tab-1"))
        #expect(payload["reason"] != nil)
        #expect(fixture.provider.relays["tab-1"] == nil, "a failed prepare kept its session")
        await fixture.close()
    }

    @Test func aTabTheAppDidNotAnnounceIsRefused() async throws {
        let fixture = try ProviderFixture()
        fixture.sources.relayReady = true
        try await fixture.connect()
        await fixture.host.send(.cdpPrepare(targetID: "elsewhere"))
        await fixture.turns.runNext()
        let payload = try await Self.answer(fixture, "tab.relay.failed")
        #expect(payload["targetId"] == .string("elsewhere"))
        await fixture.close()
    }

    @Test func captureCommandsOnTheLinkVoteUntilTheyEnd() async throws {
        let capture = DirectCapture()
        let fixture = try await Self.prepared(direct: CEFAgentDirectTarget(browser: 7, linkID: "L1"), capture: capture)
        _ = try await Self.answer(fixture, "tab.relay.direct")
        await fixture.host.send(.cdpCapture(targetID: "tab-1", capture: "screenshot", active: true, id: 1_610_612_736))
        await fixture.turns.runNext()
        #expect(capture.node.isCaptured && capture.node.effective == .hidden, "the screenshot of a hidden tab took no vote")
        await fixture.host.send(.cdpCapture(targetID: "tab-1", capture: "screencast", active: true, id: nil))
        await fixture.turns.runNext()
        #expect(capture.node.captureReasons == ["agent.screenshot", "agent.screencast"])
        await fixture.host.send(.cdpCapture(targetID: "tab-1", capture: "screenshot", active: false, id: 1_610_612_736))
        await fixture.turns.runNext()
        #expect(capture.node.captureReasons == ["agent.screencast"], "the answered screenshot kept its vote")
        // The relay's end ends the screencast's vote.
        await fixture.host.send(.cdpDetach(targetID: "tab-1"))
        await fixture.turns.runNext()
        #expect(!capture.node.isCaptured, "the detached relay kept a vote")
        await fixture.close()
    }

    /// A tab a pane showed after the prepare and then let go is in no app window: Chromium draws no frame for
    /// it, so a capture on the link would never answer. Each capture that starts puts it in the render window
    /// first (``ProviderDevToolsRelay/keepRendering(targetID:)``), then takes its vote, as the app's own relay
    /// does on each send.
    @Test func aCaptureOnTheLinkKeepsTheTabRenderingBeforeItsVote() async throws {
        let capture = DirectCapture()
        let fixture = try await Self.prepared(direct: CEFAgentDirectTarget(browser: 7, linkID: "L1"), capture: capture)
        _ = try await Self.answer(fixture, "tab.relay.direct")
        fixture.sources.onKeepRendering = { capture.order.append("render \($0)") }
        await fixture.host.send(.cdpCapture(targetID: "tab-1", capture: "screenshot", active: true, id: 1_610_612_736))
        await fixture.turns.runNext()
        #expect(capture.order == ["render tab-1", "vote agent.screenshot"])
        await fixture.host.send(.cdpCapture(targetID: "tab-1", capture: "screenshot", active: false, id: 1_610_612_736))
        await fixture.turns.runNext()
        #expect(capture.order.count == 2, "a capture's end asked for rendering")
        await fixture.host.send(.cdpCapture(targetID: "tab-1", capture: "screencast", active: true, id: nil))
        await fixture.turns.runNext()
        #expect(Array(capture.order.suffix(2)) == ["render tab-1", "vote agent.screencast"])
        await fixture.close()
    }

    /// The browser host ends the Chromium Host's relay link with the provider connection, so the app takes the
    /// link back when the connection drops and gives it again at the next `hello.ack`: a host told the same
    /// link twice would otherwise never dial the browser host again.
    @Test func theRelayLinkLivesWithTheProviderConnection() async throws {
        let linking = RelayLinks()
        let fixture = try ProviderFixture()
        fixture.provider.relayLinking = linking
        try await fixture.connect()
        await Self.until { !linking.links.isEmpty }
        let link = try #require(linking.links.first ?? nil, "the accepted hello gave no relay link")
        #expect(link.linkID == fixture.provider.relayLinkID)
        #expect(link.credential == ProviderSecret("test-secret").relayCredential.value)
        await fixture.host.dropLink()
        await Self.until { linking.links.count >= 2 }
        #expect(linking.links.count == 2 && linking.links.last == .some(nil), "a dropped connection kept the relay link")
        await fixture.close()
        withExtendedLifetime(linking) {}
    }

    @Test func aSecondPrepareOfAPreparedTabNamesItAgain() async throws {
        let fixture = try await Self.prepared(direct: CEFAgentDirectTarget(browser: 7, linkID: "L1"))
        _ = try await Self.answer(fixture, "tab.relay.direct")
        await fixture.host.send(.cdpPrepare(targetID: "tab-1"))
        await fixture.turns.runNext()
        let again = try await Self.answer(fixture, "tab.relay.direct")
        #expect(again["browser"] == .number(7))
        await fixture.close()
    }
}

extension BrowserHostProviderDirectRelayTests {
    /// A provider whose host sent `cdp.prepare` for hidden CEF tab `tab-1`.
    static func prepared(direct: CEFAgentDirectTarget?, ready: Bool = true,
                         capture: (any ProviderCaptureVoting)? = nil) async throws -> ProviderFixture {
        let fixture = try ProviderFixture(capture: capture)
        fixture.sources.relayReady = ready
        fixture.sources.direct = direct
        fixture.sources.list.tabs = [ProviderTab(targetID: "tab-1", engine: .cef, workspace: "w", profile: "p",
                                                 url: "https://example.com/", title: "Example", visible: false)]
        try await fixture.connect()
        await fixture.host.send(.cdpPrepare(targetID: "tab-1"))
        await fixture.turns.runNext()
        return fixture
    }

    /// Lets the provider's link task run until `done`, for at most 5 s.
    static func until(_ done: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < end { await Task.yield() }
    }

    /// The payload of the next `name` event the app sent.
    static func answer(_ fixture: ProviderFixture, _ name: String) async throws -> [String: DriverJSON] {
        let frame = try await fixture.host.next { if case .event(name, _) = $0 { true } else { false } }
        guard case .event(_, .object(let payload)) = frame else { return [:] }
        return payload
    }
}

/// One tab node that captures vote on.
@MainActor
private final class DirectCapture: ProviderCaptureVoting {
    let node = VisibilityNode(root: "tab:tab-1", own: .hidden)
    /// Each vote taken, as `vote <reason>`, with what a test adds between them.
    var order: [String] = []

    func captureVote(targetID: String, reason: String) -> VisibilityCaptureVote? {
        guard targetID == "tab-1" else { return nil }
        order.append("vote \(reason)")
        return node.captureVote(reason: reason, stayHidden: true)
    }
}

/// The relay links the provider gave its Chromium Host, nil for each end, in order.
@MainActor
private final class RelayLinks: ProviderRelayLinking {
    var links: [ChromiumHostRelayLink?] = []

    func setRelayLink(_ link: ChromiumHostRelayLink?) { links.append(link) }
}
