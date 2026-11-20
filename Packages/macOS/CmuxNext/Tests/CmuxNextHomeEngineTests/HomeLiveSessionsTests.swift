import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Home keeps live only the conversations a window shows, those with a send unconfirmed, and the
/// 8 others used last (design sweep 2026-11-18, item 18): before, every conversation opened once
/// stayed live for the app's life and each reconnect of the Chief owner reloaded every one.
@MainActor
struct HomeLiveSessionsTests {
    static func session(_ id: String) -> HomeConversationSession { HomeConversationSession(id: id) }

    @Test func openingManyConversationsKeepsTheLiveSetBounded() {
        var live = HomeLiveSessions()
        for index in 0..<200 { live.insert(Self.session("c\(index)"), for: "c\(index)") }
        #expect(live.count == HomeLiveSessions.defaultIdleCap, "\(live.count) conversations stayed live after 200 opens")
        #expect(live["c199"] != nil, "the conversation opened last left the live set")
        #expect(live["c0"] == nil, "the conversation opened first stayed live")
        #expect(live.trimmed().count == HomeLiveSessions.defaultIdleCap, "a reconnect reloads more than the live set")
        #expect(live.use("c0") == nil, "a dropped conversation still answered as live: it must load again")
    }

    @Test func aShownConversationStaysLive() {
        var live = HomeLiveSessions()
        let shown = Self.session("shown")
        let token = shown.observe { _ in }
        live.insert(shown, for: "shown")
        for index in 0..<50 { live.insert(Self.session("c\(index)"), for: "c\(index)") }
        #expect(live["shown"] === shown, "a conversation a window shows left the live set")
        #expect(live.count == HomeLiveSessions.defaultIdleCap + 1)
        shown.removeObserver(token)
        live.trim()
        #expect(live["shown"] == nil, "a conversation no window shows any more stayed past the cap")
    }

    @Test func aConversationWithAnUnconfirmedSendStaysLive() {
        var live = HomeLiveSessions()
        let sending = Self.session("sending")
        sending.addPending(PendingConversationSend(clientMsgID: "c_1", conversation: "sending", parts: [.text("hi", runs: [])],
                                                   replyTo: nil, createdAt: Date()))
        live.insert(sending, for: "sending")
        for index in 0..<50 { live.insert(Self.session("c\(index)"), for: "c\(index)") }
        #expect(live["sending"] === sending, "a send waiting for the owner lost its conversation")
    }

    /// A use moves a conversation to the end: the one used again outlives later ones.
    @Test func aConversationUsedAgainStaysLive() {
        var live = HomeLiveSessions(idleCap: 2)
        live.insert(Self.session("a"), for: "a")
        live.insert(Self.session("b"), for: "b")
        live.touch("a")
        live.insert(Self.session("c"), for: "c")
        #expect(live["a"] != nil)
        #expect(live["b"] == nil)
        #expect(live["c"] != nil)
    }
}
