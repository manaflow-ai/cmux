import CmuxNextBrowser
import CmuxNextBrowserAutomation
import Foundation
import Testing
@testable import CmuxNextBrowserHost

/// The CEF DevTools relay through the provider: the page is made agent-ready
/// before any message reaches it, ids are remapped both ways, events pass
/// unchanged, and failures answer the host's commands with CDP errors.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BrowserHostProviderRelayTests {
    func attached(prepare hold: Bool = false) async -> (ProviderHarness, FakeHost) {
        let h = ProviderHarness(tabs: [tab("c1", .cef)])
        h.relay.holdsPrepare = hold
        let (host, _) = await h.connected()
        _ = await host.next() // tab.access
        host.ack()
        host.send(.cdpAttach(targetID: "c1"))
        return (h, host)
    }

    @Test func idsAreRemappedBothWaysAndEventsPass() async throws {
        let (h, host) = await attached()
        host.send(.cdp(targetID: "c1", message: #"{"id":1,"method":"Target.getTargetInfo"}"#))
        #expect(await host.next() == .cdp(targetID: "c1", message: #"{"id":1,"result":{"ok":true}}"#))
        #expect(h.relay.sent == [#"{"id":1073741824,"method":"Target.getTargetInfo"}"#])
        // The tab became agent-driven at attach, before any message.
        #expect(h.marking.marked == ["c1"])

        host.send(.cdp(targetID: "c1", message: #"{"id":2,"method":"Runtime.enable","sessionId":"S"}"#))
        #expect(await host.next() == .cdp(targetID: "c1", message: #"{"id":2,"result":{"ok":true},"sessionId":"S"}"#))
        #expect(h.relay.sent.last == #"{"id":1073741825,"method":"Runtime.enable","sessionId":"S"}"#)

        // A reply nobody asked for is dropped; an event passes as it is.
        h.relay.onMessage?(#"{"id":1073741900,"result":{}}"#)
        let event = #"{"method":"Page.frameNavigated","params":{"frame":{"id":"F"}},"sessionId":"S"}"#
        h.relay.onMessage?(event)
        #expect(await host.next() == .cdp(targetID: "c1", message: event))
    }

    @Test func commandsWaitForThePageThenFlowInOrder() async throws {
        let (h, host) = await attached(prepare: true)
        host.send(.cdp(targetID: "c1", message: #"{"id":1,"method":"A"}"#))
        host.send(.cdp(targetID: "c1", message: #"{"id":2,"method":"B"}"#))
        // Both wait in the queue: the prepare deadline is the only sleeper.
        await h.clock.sleepers(atLeast: 1)
        host.send(.call(id: 9, method: "tabs.list", params: .null))
        _ = await host.next() // the call's result: both cdp frames were read before it
        #expect(h.relay.sent.isEmpty)
        h.relay.releasePrepare(true)
        #expect(await host.next() == .cdp(targetID: "c1", message: #"{"id":1,"result":{"ok":true}}"#))
        #expect(await host.next() == .cdp(targetID: "c1", message: #"{"id":2,"result":{"ok":true}}"#))
        #expect(h.relay.sent == [#"{"id":1073741824,"method":"A"}"#, #"{"id":1073741825,"method":"B"}"#])
    }

    @Test func aPageThatDoesNotStartInTimeAnswersWithCDPErrors() async throws {
        let (h, host) = await attached(prepare: true)
        host.send(.cdp(targetID: "c1", message: #"{"id":7,"method":"Target.getTargetInfo","sessionId":"S"}"#))
        await h.clock.sleepers(atLeast: 1)
        host.send(.call(id: 9, method: "tabs.list", params: .null))
        _ = await host.next()
        h.clock.advance(by: .seconds(8))
        guard case .cdp("c1", let reply)? = await host.next() else {
            Issue.record("expected a cdp error reply")
            return
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(object["id"] as? Int == 7)
        #expect(object["sessionId"] as? String == "S")
        #expect((object["error"] as? [String: Any])?["code"] as? Int == -32000)
        // A late ready does not start the relay; later commands fail too.
        h.relay.releasePrepare(true)
        host.send(.cdp(targetID: "c1", message: #"{"id":8,"method":"M"}"#))
        guard case .cdp("c1", let later)? = await host.next() else {
            Issue.record("expected a second error reply")
            return
        }
        #expect(later.contains(#""id":8"#) && later.contains("error"))
        #expect(h.relay.sent.isEmpty)
    }

    @Test func aBrowserThatEndsUnderTheRelayIsReportedAndDetachStops() async throws {
        let (h, host) = await attached()
        host.send(.cdp(targetID: "c1", message: #"{"id":1,"method":"M"}"#))
        _ = await host.next()
        h.relay.onEnd?()
        #expect(await host.next() == .event(name: "tab.relay.closed", payload: .object(["targetId": .string("c1")])))
        // No relay now: commands are refused until the host attaches again.
        host.send(.cdp(targetID: "c1", message: #"{"id":2,"method":"M"}"#))
        guard case .cdp("c1", let refused)? = await host.next() else {
            Issue.record("expected an error reply")
            return
        }
        #expect(refused.contains("error"))

        host.send(.cdpAttach(targetID: "c1"))
        host.send(.cdp(targetID: "c1", message: #"{"id":3,"method":"M"}"#))
        _ = await host.next()
        host.send(.cdpDetach(targetID: "c1"))
        host.send(.call(id: 9, method: "tabs.list", params: .null))
        _ = await host.next()
        #expect(h.relay.stopped == ["c1"])
    }

    @Test func aClosedTabEndsItsRelayAndTheHostHearsTabGone() async throws {
        let (h, host) = await attached()
        host.send(.cdp(targetID: "c1", message: #"{"id":1,"method":"M"}"#))
        _ = await host.next()
        h.tabs.providerTabs = []
        #expect(await host.next() == .event(name: "tab.gone", payload: .object(["targetId": .string("c1")])))
        #expect(h.relay.stopped == ["c1"])
    }
}
