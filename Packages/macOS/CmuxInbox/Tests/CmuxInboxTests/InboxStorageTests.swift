import Foundation
import Testing
@testable import CmuxInbox

@Suite struct InboxStorageTests {
    private let fixtures = InboxFixtures()

    @Test func migrationsAreIdempotentAndPersistCoreSchema() async throws {
        let url = fixtures.temporaryDatabaseURL()
        let store = try InboxSQLiteStore(databaseURL: url)

        try await store.runMigrations()
        try await store.runMigrations()

        let account = fixtures.account(source: .gmail, accountID: "me")
        let thread = fixtures.thread(source: .gmail, accountID: "me", title: "Launch mail")
        let item = fixtures.item(
            source: .gmail,
            accountID: "me",
            threadID: thread.threadID,
            preview: "Migration smoke",
            body: "Schema survived repeated migration"
        )
        try await store.upsertAccount(account)
        try await store.upsertThread(thread)
        try await store.upsertItem(item)

        let rows = try await store.list(InboxListQuery(filter: .all, source: .gmail, limit: 10))
        #expect(rows.map { $0.itemID } == [item.itemID])
    }

    @Test func dedupesExternalMessagesAndRefreshesUnreadCounts() async throws {
        let store = try InboxSQLiteStore(databaseURL: fixtures.temporaryDatabaseURL())
        let thread = fixtures.thread(source: .slack, accountID: "team", title: "#alerts")
        try await store.upsertThread(thread)

        let first = fixtures.item(
            source: .slack,
            accountID: "team",
            threadID: thread.threadID,
            suffix: "same",
            preview: "first",
            unread: true,
            actionable: true
        )
        var updated = first
        updated.bodyPreview = "updated"
        updated.isUnread = false
        updated.isActionable = false
        try await store.upsertItem(first)
        try await store.upsertItem(updated)

        let rows = try await store.list(InboxListQuery(filter: .all, source: .slack, limit: 10))
        #expect(rows.count == 1)
        #expect(rows.first?.bodyPreview == "updated")

        let refreshed = try #require(try await store.thread(id: thread.threadID))
        #expect(refreshed.unreadCount == 0)
        let loadedThreads = try await store.threads(ids: [thread.threadID, thread.threadID, "missing"])
        #expect(loadedThreads.map(\.threadID) == [thread.threadID])

        let counts = try await store.unreadCounts()
        #expect(counts.first(where: { $0.source == .slack }) == nil)

        try await store.markRead(threadID: thread.threadID, unread: true)
        let unreadCounts = try await store.unreadCounts()
        #expect(unreadCounts.first(where: { $0.source == .slack })?.unreadCount == 1)
    }

    @Test func fullTextSearchFindsIndexedInboxBodies() async throws {
        let store = try InboxSQLiteStore(databaseURL: fixtures.temporaryDatabaseURL())
        let thread = fixtures.thread(source: .generic, title: "Ops")
        let item = fixtures.item(
            source: .generic,
            threadID: thread.threadID,
            preview: "Pager alert",
            body: "Database pager escalation needs attention"
        )
        try await store.upsertThread(thread)
        try await store.upsertItem(item)

        let hits = try await store.search("pager escalation", limit: 10)
        #expect(hits.map(\.item.itemID) == [item.itemID])
        #expect(hits.first?.thread.threadID == thread.threadID)
    }

    @Test func agentSourceItemsRoundTripForFeedMirroringCompatibility() async throws {
        let store = try InboxSQLiteStore(databaseURL: fixtures.temporaryDatabaseURL())
        let thread = fixtures.thread(source: .agent, accountID: "workstream", title: "Agent approval")
        let item = fixtures.item(
            source: .agent,
            accountID: "workstream",
            threadID: thread.threadID,
            preview: "Plan approval required",
            actionable: true
        )
        try await store.upsertAccount(fixtures.account(source: .agent, accountID: "workstream"))
        try await store.upsertThread(thread)
        try await store.upsertItem(item)

        let agentRows = try await store.list(InboxListQuery(filter: .actionable, source: .agent, limit: 10))
        let gmailRows = try await store.list(InboxListQuery(filter: .all, source: .gmail, limit: 10))
        #expect(agentRows.map { $0.itemID } == [item.itemID])
        #expect(gmailRows.isEmpty)
    }

    @Test func syncUpsertDoesNotResurrectLocallyReadItems() async throws {
        let store = try InboxSQLiteStore(databaseURL: fixtures.temporaryDatabaseURL())
        let thread = fixtures.thread(source: .slack, accountID: "team", title: "#alerts")
        try await store.upsertThread(thread)
        let remote = fixtures.item(source: .slack, accountID: "team", threadID: thread.threadID, suffix: "sticky", unread: true)
        try await store.upsertItem(remote)
        try await store.markRead(itemID: remote.itemID)

        // The remote copy is still unread on the next sync; connectors without
        // remote mark-read must not flip the local read back.
        try await store.upsertItem(remote)
        let rows = try await store.list(InboxListQuery(filter: .all, source: .slack, limit: 10))
        #expect(rows.first?.isUnread == false)

        // A genuine remote read signal still applies to a locally-unread item.
        let second = fixtures.item(source: .slack, accountID: "team", threadID: thread.threadID, suffix: "remote-read", unread: true)
        try await store.upsertItem(second)
        var readRemote = second
        readRemote.isUnread = false
        try await store.upsertItem(readRemote)
        let updated = try await store.list(InboxListQuery(filter: .all, source: .slack, limit: 10))
        #expect(updated.first { $0.itemID == second.itemID }?.isUnread == false)
    }

    @Test func unreadCountsExcludeReadActionableItems() async throws {
        let store = try InboxSQLiteStore(databaseURL: fixtures.temporaryDatabaseURL())
        let thread = fixtures.thread(source: .discord, title: "#ops")
        try await store.upsertThread(thread)
        try await store.upsertItem(fixtures.item(
            source: .discord,
            threadID: thread.threadID,
            suffix: "handled",
            unread: false,
            actionable: true
        ))

        // A read-but-still-actionable item must not inflate the unread badge.
        let counts = try #require(try await store.unreadCounts().first { $0.source == .discord })
        #expect(counts.unreadCount == 0)
        #expect(counts.actionableCount == 1)

        try await store.upsertItem(fixtures.item(
            source: .discord,
            threadID: thread.threadID,
            suffix: "fresh",
            unread: true,
            actionable: false
        ))
        let updated = try #require(try await store.unreadCounts().first { $0.source == .discord })
        #expect(updated.unreadCount == 1)
        #expect(updated.actionableCount == 1)
    }

    @Test func accountUpsertPreservesNotificationsOptOut() async throws {
        let store = try InboxSQLiteStore(databaseURL: fixtures.temporaryDatabaseURL())
        let account = fixtures.account(source: .slack, accountID: "default")
        try await store.upsertAccount(account)
        try await store.setNotificationsEnabled(source: .slack, accountID: "default", enabled: false)

        // Sync/push paths rebuild account records with the default
        // notificationsEnabled=true; the status upsert must not clobber the
        // stored opt-out.
        var statusRefresh = account
        statusRefresh.status = .degraded
        statusRefresh.statusMessage = "Configure Slack channel IDs to enable backfill"
        try await store.upsertAccount(statusRefresh)

        let stored = try #require(try await store.accounts().first { $0.source == .slack })
        #expect(stored.notificationsEnabled == false)
        #expect(stored.status == .degraded)

        try await store.setNotificationsEnabled(source: .slack, accountID: "default", enabled: true)
        let reenabled = try #require(try await store.accounts().first { $0.source == .slack })
        #expect(reenabled.notificationsEnabled == true)
    }
}
