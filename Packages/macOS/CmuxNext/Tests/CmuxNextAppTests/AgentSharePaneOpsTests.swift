import AppKit
@testable import CmuxNextApp
import CmuxNextAgentPane
import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Foundation
import Testing

/// The chat's Share dialog (`share.op`): every op acts on the asking tab's own chat. A tab with no
/// started chat is refused before the daemon is asked, `state` lists only this chat's shares, and a
/// revoke never ends another chat's link.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AgentSharePaneOpsTests {
    static let session = AgentShareTests.session

    @Test func aTabWithNoStartedChatOnThisMacIsRefused() async {
        let fixture = AgentShareTests.fixture()
        for tab in [fixture.newChat.id, fixture.terminal.id, "no-such-tab"] {
            guard case .refused(let code, _) = await AgentShareActions.pane(.state, tab: tab, host: fixture.services) else {
                Issue.record("\(tab) answered")
                continue
            }
            #expect(code == "unavailable")
        }
    }

    @Test func aPinnedSessionTheTabNoLongerShowsIsRefused() async {
        let fixture = AgentShareTests.fixture()
        guard case .refused(let code, _) = await AgentShareActions.pane(.state, session: "another-chat", tab: fixture.chat.id,
                                                                          host: fixture.services) else {
            Issue.record("a moved chat answered")
            return
        }
        #expect(code == "unavailable")
    }

    @Test func aRevokeTakesOnlyAShareOfThisChat() {
        let shares = [
            AgentSessionShare(shareId: "mine", state: "active", session: Self.session, surface: 1),
            AgentSessionShare(shareId: "other", state: "active", session: "another-chat", surface: 1),
        ]
        #expect(AgentSharePaneState.isShare("mine", of: Self.session, in: shares))
        #expect(!AgentSharePaneState.isShare("other", of: Self.session, in: shares), "another chat's link on the same surface")
        #expect(!AgentSharePaneState.isShare("missing", of: Self.session, in: shares))
    }

    @Test func stateListsThisChatsSharesInThePagesKeys() throws {
        let shares = [
            AgentSessionShare(shareId: "s1", state: "active", session: Self.session, surface: 1, createdAt: 5, expiresAt: 9, usesLeft: 999,
                              inviteUrl: "https://room.example/i/s1",
                              guests: [AgentSessionShareGuest(guestId: "g1", name: "Ada", joinedAt: 6, state: "active", account: "ada@x.co", role: "view"),
                                       AgentSessionShareGuest(guestId: "g2", name: "Bob", joinedAt: 7, state: "left")],
                              invitees: [AgentSessionShareInvitee(account: "ada@x.co", role: "view", invitedAt: 4, state: "invited"),
                                         AgentSessionShareInvitee(account: "cy@x.co", role: "talk", invitedAt: 4, state: "invited")],
                              role: "view"),
            AgentSessionShare(shareId: "s2", state: "active", session: "another-chat", surface: 1),
        ]
        let listed = AgentSharePaneState.shares(of: Self.session, in: shares)
        #expect(listed.count == 1)
        let share = try #require(listed.first)
        #expect(share["shareId"] as? String == "s1")
        #expect(share["url"] is NSNull, "the link's secret is never kept")
        #expect(share["role"] as? String == "view")
        #expect(share["usesLeft"] as? Int == 999)
        let guests = try #require(share["guests"] as? [[String: Any]])
        #expect(guests.map { $0["joined"] as? Bool } == [true, false])
        #expect(guests[1]["account"] is NSNull)
        let invitees = try #require(share["invitees"] as? [[String: Any]])
        #expect(invitees.map { $0["joined"] as? Bool } == [true, false])
        // Whatever the page reads, it can serialize.
        #expect(JSONSerialization.isValidJSONObject(["shares": listed]))
    }

    @Test func aCreateWithNoRoleLeavesTheFieldOut() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let plain = try #require(try JSONSerialization.jsonObject(with: encoder.encode(AgentSessionShareCreateRequest(surface: 1))) as? [String: Any])
        #expect(plain["role"] == nil, "a daemon older than link roles refuses an unknown field")
        let viewer = try #require(try JSONSerialization.jsonObject(with: encoder.encode(AgentSessionShareCreateRequest(surface: 1, role: "view"))) as? [String: Any])
        #expect(viewer["role"] as? String == "view")
        let decoded = try JSONDecoder().decode(AgentSessionShare.self, from: Data(#"{"state":"active","share_id":"s","session":"c","surface":1,"created_at":1,"expires_at":2,"expires_in_secs":1,"uses_left":3,"guests":[],"role":"view"}"#.utf8))
        #expect(decoded.role == "view")
    }
}
