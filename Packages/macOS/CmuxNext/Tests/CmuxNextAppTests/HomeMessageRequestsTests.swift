import AppKit
import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
@testable import CmuxNextHomeEngine
import Testing

/// Message requests on the Mac (plans/cmux-next/home-messaging-invites/DESIGN.md 2.3, 2.5): a
/// stranger's invite waits under Message Requests with Accept, Decline and Block; the sender's
/// row says who it waits for; no internal id is ever shown.
@MainActor
struct HomeMessageRequestsTests {
    static let austin = HomeMessageRequest(conversation: ConversationID("conv_dm_0Y05MEWEFMQQB63VDHQB9MXAJS"), inviter: "Lawrence Chen",
                                           isGroup: false, title: nil, preview: "hi", createdAt: nil, trusted: false)
    static let lunch = HomeMessageRequest(conversation: ConversationID("conv_0Y05MEWEFMQQB63VDHQB9MXAJT"), inviter: "Frank",
                                          isGroup: true, title: "Lunch", preview: "", createdAt: nil, trusted: true)

    @Test func theSidebarShowsTheRequestCountOnlyWhenThereAreRequests() {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        var opened = 0
        home.onOpenRequests = { opened += 1 }
        home.showRequests(0)
        #expect(home.requestsButton.isHidden)
        home.showRequests(2)
        #expect(!home.requestsButton.isHidden)
        #expect(home.requestsButton.title == HomeConversationStrings.requestsBar(2))
        #expect(!home.requestsButton.title.contains("addr_"))
        home.requestsButton.performClick(nil)
        #expect(opened == 1)
    }

    @Test func theSheetOffersAcceptDeclineAndBlockPerRequest() async throws {
        let sheet = HomeRequestsSheet(requests: [Self.austin, Self.lunch])
        var answered: [(ConversationID, HomeRequestAnswer)] = []
        sheet.onAnswer = { id, answer in answered.append((id, answer)); return true }
        _ = sheet.view
        let text = sheet.view.homeAllText
        #expect(text.contains("Lawrence Chen"))
        #expect(text.contains("Lunch"))
        #expect(!text.contains("addr_"))
        let block = try #require(sheet.view.homeButton(identifier: "cmux.home.requests.block.\(Self.lunch.conversation.rawValue)"))
        block.performClick(nil)
        for _ in 0..<50 where answered.isEmpty { await Task.yield() }
        #expect(answered.map(\.0) == [Self.lunch.conversation])
        #expect(answered.map(\.1) == [.block])
        #expect(sheet.view.homeButton(identifier: "cmux.home.requests.accept.\(Self.austin.conversation.rawValue)") != nil)
        #expect(sheet.view.homeButton(identifier: "cmux.home.requests.decline.\(Self.austin.conversation.rawValue)") != nil)
    }

    @Test func theSenderSeesWhoTheInviteWaitsForNeverAnID() {
        let me = Participant(id: ParticipantID("user_local"), kind: .human, displayName: "Lawrence")
        let masked = Participant(id: ParticipantID("addr_ABREQ2MXXDJ3CH86MMYYKA0FPC"), kind: .human, displayName: "",
                                 membership: .invited, invitedContact: "a***@manaflow.ai")
        let named = ConversationSummary(id: ConversationID("conv_dm_0Y05MEWEFMQQB63VDHQB9MXAJS"), participants: [me, masked],
                                        createdAt: .distantPast, updatedAt: .distantPast)
        #expect(named.homeInviteWaiting(me: me.id) == HomeConversationStrings.waitingFor("a***@manaflow.ai"))
        let bare = Participant(id: ParticipantID("addr_ABREQ2MXXDJ3CH86MMYYKA0FPC"), kind: .human,
                               displayName: "addr_ABREQ2MXXDJ3CH86MMYYKA0FPC", membership: .invited)
        let unnamed = ConversationSummary(id: named.id, participants: [me, bare], createdAt: .distantPast, updatedAt: .distantPast)
        let shown = unnamed.homeInviteWaiting(me: me.id)
        #expect(shown == HomeConversationStrings.invitedLabel)
        #expect(shown?.contains("addr_") == false)
        let joined = ConversationSummary(id: named.id, participants: [me, Participant(id: ParticipantID("user_austin"), kind: .human, displayName: "Austin")],
                                         createdAt: .distantPast, updatedAt: .distantPast)
        #expect(joined.homeInviteWaiting(me: me.id) == nil)
    }
}

extension NSView {
    /// Every label's and button's text under this view. Labels are read through `ShownText`, so a
    /// ``ChromeLabel`` (its own view, not an `NSTextField`) counts as well as a stock field.
    var homeAllText: String {
        var parts: [String] = []
        if let label = self as? any ShownText { parts.append(label.stringValue) }
        if let button = self as? NSButton { parts.append(button.title) }
        return (parts + subviews.map(\.homeAllText)).joined(separator: "\n")
    }

    func homeButton(identifier: String) -> NSButton? {
        if let button = self as? NSButton, button.accessibilityIdentifier() == identifier { return button }
        for view in subviews { if let found = view.homeButton(identifier: identifier) { return found } }
        return nil
    }
}
