@testable import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing

/// A probe reads a remote chat's link state and its first live paint from `cmux events`, not
/// from the window's accessibility tree; a chat on this Mac publishes nothing.
@MainActor
struct RemoteChatEventsTests {
    final class Published { var events: [(name: String, payload: [String: JSONValue])] = [] }

    @Test func linkStatesAndALivePaintArePublished() {
        let published = Published()
        let events = RemoteChatEvents()
        events.publish = { published.events.append(($0, $1)) }
        events.peerOf = { $0 == "walk-remote/chat" ? "walk-remote" : nil }
        events.now = { Date(timeIntervalSince1970: 1_700_000_000.25) }

        events.linkChanged(peer: "walk-remote", state: "reconnecting")
        events.linkChanged(peer: nil, state: "connected")
        events.linkChanged(peer: "walk-remote", state: "")
        events.linkChanged(peer: "walk-remote", state: "connected")
        events.livePainted(session: "walk-remote/chat")
        events.livePainted(session: "local-chat")
        events.livePainted(session: nil)

        #expect(published.events.map(\.name) == [RemoteChatEvents.linkEvent, RemoteChatEvents.linkEvent, RemoteChatEvents.livePaintEvent])
        #expect(published.events[0].payload["state"] == .string("reconnecting"))
        #expect(published.events[0].payload["at_ms"] == .number(1_700_000_000_250))
        let paint = published.events[2].payload
        #expect(paint["session"] == .string("walk-remote/chat") && paint["peer"] == .string("walk-remote"))
        #expect(paint["link"] == .string("connected"))
    }

    @Test func eachMachineLinkCarriesItsEvents() {
        let link = AgentPaneMachineLink()
        link.events.linkChanged(peer: "walk-remote", state: "offline")
        #expect(link.events.links["walk-remote"] == "offline")
    }
}
