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

    @Test func feedSectionsBucketRowsByRecencyAndDropEmptyBuckets() {
        let model = InboxPresentationModel()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2023-11-15 12:00:00 UTC
        let now = Date(timeIntervalSince1970: 1_700_049_600)
        let thread = fixtures.thread()

        func row(minutesAgo: Double, suffix: String) -> InboxRowSnapshot {
            let item = InboxItem(
                itemID: "item-\(suffix)",
                threadID: thread.threadID,
                source: .generic,
                accountID: "default",
                externalMessageID: "external-\(suffix)",
                sender: InboxParticipant(displayName: "Sender"),
                timestamp: now.addingTimeInterval(-minutesAgo * 60),
                bodyPreview: suffix
            )
            return InboxRowSnapshot(item: item, thread: thread)
        }

        let rows = [
            row(minutesAgo: -30, suffix: "future"),
            row(minutesAgo: 60, suffix: "today"),
            row(minutesAgo: 26 * 60, suffix: "yesterday"),
            row(minutesAgo: 4 * 24 * 60, suffix: "this-week"),
            row(minutesAgo: 30 * 24 * 60, suffix: "earlier"),
        ]
        let sections = model.feedSections(rows: rows, now: now, calendar: calendar)

        #expect(sections.map(\.bucket) == [.today, .yesterday, .thisWeek, .earlier])
        #expect(sections.first?.rows.map(\.preview) == ["future", "today"])
        #expect(sections.last?.rows.map(\.preview) == ["earlier"])

        let recentOnly = model.feedSections(rows: [rows[1]], now: now, calendar: calendar)
        #expect(recentOnly.map(\.bucket) == [.today])
    }
}
