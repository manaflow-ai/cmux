import Foundation
import Testing
import CmuxInbox

@Suite struct InboxPresentationTests {
    private let fixtures = InboxFixtures()

    @Test func filtersSourceChipsAndRowsUseImmutableSnapshots() {
        let model = InboxPresentationModel()
        let slackThread = fixtures.thread(source: .slack, accountID: "team", title: "#ops")
        let gmailThread = fixtures.thread(source: .gmail, accountID: "me", title: "Mail")
        let slackItem = fixtures.item(
            source: .slack,
            accountID: "team",
            threadID: slackThread.threadID,
            preview: "Deploy blocked",
            unread: true,
            actionable: true
        )
        let gmailItem = fixtures.item(
            source: .gmail,
            accountID: "me",
            threadID: gmailThread.threadID,
            preview: "Newsletter",
            unread: false
        )

        let actionableSlack = model.filteredItems([slackItem, gmailItem], filter: .actionable, source: .slack)
        #expect(actionableSlack.map(\.itemID) == [slackItem.itemID])

        let chips = model.sourceChips(
            selectedSource: .slack,
            counts: [
                InboxSourceUnreadCount(source: .slack, unreadCount: 3, actionableCount: 2),
                InboxSourceUnreadCount(source: .gmail, unreadCount: 1, actionableCount: 0),
            ],
            statuses: [
                InboxConnectorStatus(source: .slack, status: .connected, capabilities: []),
                InboxConnectorStatus(source: .slack, status: .tokenExpired, capabilities: []),
            ]
        )
        let all = chips.first(where: { $0.source == nil })
        let slack = chips.first(where: { $0.source == .slack })
        #expect(all?.unreadCount == 4)
        #expect(slack?.isSelected == true)
        #expect(slack?.status == .tokenExpired)

        let rows = model.rows(items: [slackItem], threads: [slackThread])
        #expect(rows.first?.title == "#ops")
        #expect(rows.first?.isActionable == true)
        #expect(rows.first?.externalURL == slackThread.externalURL)
    }

    @Test func draftSendStateRequiresVisibleApprovalAndBlocksEmptyDrafts() {
        let model = InboxPresentationModel()

        #expect(model.sendState(for: nil) == .noDraft)
        #expect(model.sendState(for: fixtures.draft(body: "  ")) == .emptyDraft)
        #expect(model.sendState(for: fixtures.draft(body: "Looks good")) == .requiresApproval)
        #expect(model.sendState(for: fixtures.draft(body: "Sent", status: .sent)) == .sent)
        #expect(model.sendState(for: fixtures.draft(body: "Failed", status: .failed)) == .failed)
    }
}
