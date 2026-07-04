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
            runtime.loadState = .failed(String(describing: primaryError))
            return runtime
        } catch {
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-inbox-last-resort.sqlite3")
            do {
                let store = try InboxSQLiteStore(databaseURL: fallbackURL)
                let runtime = InboxRuntime(hub: IntegrationHub(store: store, connectors: []))
                runtime.loadState = .failed(String(describing: primaryError))
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
            updateNotificationState(items: items, seed: seedNotifications)
            if let selectedThread {
                try await refreshThread(threadID: selectedThread.threadID)
            }
            loadState = .idle
        } catch {
            loadState = .failed(String(describing: error))
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
            try? await hub.markRead(itemID: itemID, threadID: threadID, unread: unread)
            await refresh(seedNotifications: true)
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
                loadState = .failed(String(describing: error))
            }
        }
    }

    func updateDraftBody(_ body: String) {
        guard let draftID = currentDraft?.draftID else { return }
        Task {
            currentDraft = try? await hub.updateDraftBody(draftID: draftID, body: body)
        }
    }

    func sendApprovedDraft() {
        guard let draftID = currentDraft?.draftID else { return }
        Task {
            do {
                currentDraft = try await hub.sendApprovedReply(draftID: draftID)
                if let threadID = currentDraft?.threadID {
                    try await refreshThread(threadID: threadID)
                }
            } catch {
                loadState = .failed(String(describing: error))
            }
        }
    }

    func openOriginal(row: InboxRowSnapshot? = nil) {
        let raw = row?.externalURL ?? selectedThread?.externalURL
        guard let raw, let url = URL(string: raw) else { return }
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
        for item in unreadItems where seenUnreadItemIDs.insert(item.itemID).inserted {
            postCmuxNotification(for: item)
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
