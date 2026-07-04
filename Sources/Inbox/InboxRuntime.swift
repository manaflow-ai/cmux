import AppKit
import CmuxInbox
import Foundation
import Observation

@MainActor
@Observable
final class InboxRuntime {
    enum LoadState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    let hub: IntegrationHub
    private let presenter = InboxPresentationModel()

    var filter: InboxListFilter = .actionable
    var selectedSource: InboxSource?
    var rows: [InboxRowSnapshot] = []
    var feedSections: [InboxFeedSection] = []
    var sourceChips: [InboxSourceChipSnapshot] = []
    var accounts: [InboxAccount] = []
    var statuses: [InboxConnectorStatus] = []
    var unreadCounts: [InboxSourceUnreadCount] = []
    var selectedThread: InboxThread?
    var recentItems: [InboxItem] = []
    var currentDraft: InboxDraft?
    var loadState: LoadState = .idle
    var isSyncing = false

    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var feedMirror: InboxFeedMirror?
    @ObservationIgnored private var hasSeededNotificationState = false
    @ObservationIgnored private var seenUnreadItemIDs = Set<String>()

    var totalUnreadCount: Int {
        unreadCounts.reduce(0) { $0 + $1.unreadCount }
    }

    static func makeProduction() -> InboxRuntime {
        do {
            return InboxRuntime(hub: try IntegrationHubFactory().makeHub())
        } catch {
            return makeFallback(primaryError: error)
        }
    }

    init(hub: IntegrationHub) {
        self.hub = hub
    }

    private static func makeFallback(primaryError: Error) -> InboxRuntime {
        do {
            let store = try InboxSQLiteStore(databaseURL: .temporaryInboxFallback)
            let runtime = InboxRuntime(hub: IntegrationHub(store: store, connectors: []))
            runtime.loadState = .failed(Self.userFacingMessage(for: primaryError))
            return runtime
        } catch {
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-inbox-last-resort.sqlite3")
            do {
                let store = try InboxSQLiteStore(databaseURL: fallbackURL)
                let runtime = InboxRuntime(hub: IntegrationHub(store: store, connectors: []))
                runtime.loadState = .failed(Self.userFacingMessage(for: primaryError))
                return runtime
            } catch {
                preconditionFailure("Unable to initialize cmux inbox storage: \(primaryError); fallback: \(error)")
            }
        }
    }

    func start() {
        guard changeTask == nil else { return }
        Task { await hub.start() }
        changeTask = Task { [weak self, hub] in
            for await _ in await hub.changes() {
                guard !Task.isCancelled else { break }
                await self?.refresh(seedNotifications: false)
            }
        }
        feedMirror = InboxFeedMirror(hub: hub)
        feedMirror?.start()
        Task { await refresh(seedNotifications: true) }
    }

    func setFilter(_ next: InboxListFilter) {
        guard filter != next else { return }
        filter = next
        Task { await refresh(seedNotifications: true) }
    }

    func setSource(_ source: InboxSource?) {
        guard selectedSource != source else { return }
        selectedSource = source
        selectedThread = nil
        recentItems = []
        currentDraft = nil
        Task { await refresh(seedNotifications: true) }
    }

    func refresh(seedNotifications: Bool = false) async {
        loadState = .loading
        do {
            async let statusTask = hub.status()
            async let countsTask = hub.unreadCounts()
            async let accountsTask = hub.accounts()
            let items = try await hub.list(InboxListQuery(filter: filter, source: selectedSource, limit: 100))
            // Notification tracking must not depend on what happens to be
            // visible: the default .actionable filter (or a selected source)
            // would silently drop notifications for every other unread item.
            let notificationCandidates = try await hub.list(InboxListQuery(filter: .unread, source: nil, limit: 100))
            let threadIDs = Array(Set(items.map(\.threadID)))
            let threads = try await hub.threads(ids: threadIDs)
            statuses = await statusTask
            unreadCounts = try await countsTask
            accounts = try await accountsTask
            sourceChips = presenter.sourceChips(
                selectedSource: selectedSource,
                counts: unreadCounts,
                statuses: statuses
            )
            rows = presenter.rows(items: items, threads: threads)
            feedSections = presenter.feedSections(rows: rows, now: Date())
            updateNotificationState(items: notificationCandidates, seed: seedNotifications)
            if let selectedThread {
                try await refreshThread(threadID: selectedThread.threadID)
            }
            loadState = .idle
        } catch {
            loadState = .failed(Self.userFacingMessage(for: error))
        }
    }

    func sync(source: InboxSource? = nil) {
        isSyncing = true
        Task {
            _ = await hub.sync(source: source)
            isSyncing = false
            await refresh(seedNotifications: true)
        }
    }

    func connect(source: InboxSource, accountID: String = "default", displayName: String? = nil, token: String? = nil) async throws {
        _ = try await hub.connect(source: source, accountID: accountID, displayName: displayName, token: token)
        await refresh(seedNotifications: true)
    }

    func disconnect(source: InboxSource, accountID: String = "default") async throws {
        _ = try await hub.disconnect(source: source, accountID: accountID)
        await refresh(seedNotifications: true)
    }

    func setNotificationsEnabled(source: InboxSource, accountID: String, enabled: Bool) async throws {
        try await hub.setNotificationsEnabled(source: source, accountID: accountID, enabled: enabled)
        await refresh(seedNotifications: true)
    }

    func markRead(itemID: String? = nil, threadID: String? = nil, unread: Bool = false) {
        Task {
            do {
                try await hub.markRead(itemID: itemID, threadID: threadID, unread: unread)
                await refresh(seedNotifications: true)
            } catch {
                // Reconcile first: refresh() resets loadState, so the failure
                // must be applied after it or the banner vanishes instantly.
                await refresh(seedNotifications: true)
                loadState = .failed(Self.userFacingMessage(for: error))
            }
        }
    }

    func selectThread(_ threadID: String) {
        Task {
            try? await refreshThread(threadID: threadID)
        }
    }

    func draftReply(threadID: String, instruction: String?) {
        Task {
            do {
                currentDraft = try await hub.draftReply(threadID: threadID, instruction: instruction)
                try await refreshThread(threadID: threadID)
            } catch {
                loadState = .failed(Self.userFacingMessage(for: error))
            }
        }
    }

    /// Keeps draft edits local while typing. Persisting per keystroke spawned
    /// unordered hub writes whose stale echoes could revert newer editor text,
    /// and each write triggered a full change-driven refresh; the body is
    /// flushed to the store once, inside `sendApprovedDraft()`.
    func updateDraftBody(_ body: String) {
        guard currentDraft != nil, currentDraft?.body != body else { return }
        currentDraft?.body = body
        currentDraft?.status = .editing
    }

    func sendApprovedDraft() {
        guard let draft = currentDraft else { return }
        Task {
            do {
                _ = try await hub.updateDraftBody(draftID: draft.draftID, body: draft.body)
                currentDraft = try await hub.sendApprovedReply(draftID: draft.draftID)
                if let threadID = currentDraft?.threadID {
                    try await refreshThread(threadID: threadID)
                }
            } catch {
                loadState = .failed(Self.userFacingMessage(for: error))
            }
        }
    }

    /// URL schemes inbox deep links may hand to NSWorkspace. externalURL comes
    /// from connector payloads and socket pushes, so arbitrary schemes (file:,
    /// app-preference URLs, ...) must not be openable from an inbox row.
    private static let allowedExternalURLSchemes: Set<String> = [
        "http", "https", "mailto", "slack", "discord", "imessage", "messages", "sms", "cmux",
    ]

    func openOriginal(row: InboxRowSnapshot? = nil) {
        let raw = row?.externalURL ?? selectedThread?.externalURL
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              Self.allowedExternalURLSchemes.contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    func push(account: InboxAccount, thread: InboxThread, item: InboxItem) async throws {
        try await hub.push(account: account, thread: thread, item: item)
        await refresh(seedNotifications: false)
    }

    func sendState() -> InboxDraftSendState {
        presenter.sendState(for: currentDraft)
    }

    private func refreshThread(threadID: String) async throws {
        // Drop a draft that belongs to a different thread immediately, before
        // any await: the detail view enables editing and Send whenever a draft
        // exists, and a stale draft could send an approved reply to the wrong
        // conversation.
        if let draft = currentDraft, draft.threadID != threadID {
            currentDraft = nil
        }
        selectedThread = try await hub.thread(id: threadID)
        recentItems = try await hub.recentItems(threadID: threadID, limit: 20)
    }

    private func updateNotificationState(items: [InboxItem], seed: Bool) {
        let unreadItems = items.filter(\.isUnread)
        if seed || !hasSeededNotificationState {
            seenUnreadItemIDs.formUnion(unreadItems.map(\.itemID))
            hasSeededNotificationState = true
            return
        }
        // Honor the per-account notification preference. Items are still
        // marked seen while muted so re-enabling never replays old previews.
        let mutedAccountIDs = Set(accounts.filter { !$0.notificationsEnabled }.map(\.id))
        for item in unreadItems where seenUnreadItemIDs.insert(item.itemID).inserted {
            guard !mutedAccountIDs.contains("\(item.source.rawValue):\(item.accountID)") else { continue }
            postCmuxNotification(for: item)
        }
    }

    /// Maps an error to user-facing panel copy. ``InboxError`` descriptions
    /// are user-shaped; anything else becomes generic localized copy instead
    /// of a raw Swift error dump.
    private static func userFacingMessage(for error: Error) -> String {
        switch error {
        case InboxError.openFailed, InboxError.prepareFailed, InboxError.stepFailed:
            return String(localized: "inbox.error.storage", defaultValue: "Inbox storage error")
        case let error as InboxError:
            return error.description
        default:
            return String(localized: "inbox.error.generic", defaultValue: "Inbox operation failed")
        }
    }

    private func postCmuxNotification(for item: InboxItem) {
        guard let workspaceId = AppDelegate.shared?.tabManager?.selectedWorkspace?.id else { return }
        TerminalNotificationStore.shared.addNotification(
            tabId: workspaceId,
            surfaceId: nil,
            title: InboxLocalized.sourceLabel(item.source),
            subtitle: item.sender.displayName,
            body: item.bodyPreview,
            cooldownKey: "inbox:\(item.source.rawValue):\(item.threadID)",
            cooldownInterval: 15
        )
    }
}

private extension URL {
    static var temporaryInboxFallback: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-inbox-fallback-\(UUID().uuidString).sqlite3")
    }
}
