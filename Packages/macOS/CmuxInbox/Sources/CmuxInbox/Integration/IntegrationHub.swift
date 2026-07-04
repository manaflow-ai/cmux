import Foundation

/// Owns connector lifecycle, sync state, dedupe fanout, and shared inbox mutations.
public actor IntegrationHub {
    private let store: InboxSQLiteStore
    private let connectors: [InboxSource: any InboxConnector]
    private let tokenStore: (any InboxTokenStoring)?
    private var continuations: [UUID: AsyncStream<InboxChange>.Continuation] = [:]
    private var eventTasks: [InboxSource: Task<Void, Never>] = [:]

    /// Creates an integration hub.
    /// - Parameters:
    ///   - store: Local inbox store.
    ///   - connectors: Connector instances keyed by source.
    ///   - tokenStore: Optional secure token store for connect/disconnect actions.
    public init(
        store: InboxSQLiteStore,
        connectors: [any InboxConnector],
        tokenStore: (any InboxTokenStoring)? = nil
    ) {
        self.store = store
        self.tokenStore = tokenStore
        self.connectors = Dictionary(uniqueKeysWithValues: connectors.map { ($0.source, $0) })
    }

    deinit {
        for task in eventTasks.values {
            task.cancel()
        }
    }

    /// Starts connector live-event tasks once.
    public func start() {
        for connector in connectors.values where eventTasks[connector.source] == nil {
            let source = connector.source
            eventTasks[source] = Task { [connector] in
                for await event in connector.events() {
                    await self.ingest(event)
                }
            }
        }
    }

    /// Returns an async stream of local inbox changes.
    public func changes() -> AsyncStream<InboxChange> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    /// Returns connector and persisted account status, merged by
    /// (source, account id). A live connector status only reflects credential
    /// presence, so a persisted failure state from the last sync overrides a
    /// credential-healthy "connected" until a successful sync clears it.
    public func status(source: InboxSource? = nil) async -> [InboxConnectorStatus] {
        var statuses: [InboxConnectorStatus] = []
        let knownAccounts = (try? await store.accounts()) ?? []
        let accountsByID = Dictionary(uniqueKeysWithValues: knownAccounts.map { ($0.id, $0) })
        for connector in connectors.values where source == nil || connector.source == source {
            var live = await connector.status()
            if live.status == .connected,
               let accountID = live.accountID,
               let stored = accountsByID["\(connector.source.rawValue):\(accountID)"],
               Self.persistedFailureStates.contains(stored.status) {
                live = InboxConnectorStatus(
                    source: live.source,
                    accountID: accountID,
                    displayName: live.displayName,
                    status: stored.status,
                    message: stored.statusMessage,
                    credentialState: live.credentialState,
                    capabilities: live.capabilities,
                    lastSyncAt: stored.lastSyncAt ?? live.lastSyncAt
                )
            }
            statuses.append(live)
        }
        for account in knownAccounts where source == nil || account.source == source {
            guard !statuses.contains(where: { $0.source == account.source && $0.accountID == account.accountID }) else { continue }
            statuses.append(InboxConnectorStatus(
                source: account.source,
                accountID: account.accountID,
                displayName: account.displayName,
                status: account.status,
                message: account.statusMessage,
                credentialState: .missing,
                capabilities: account.capabilities,
                lastSyncAt: account.lastSyncAt
            ))
        }
        return statuses.sorted { $0.id < $1.id }
    }

    /// Persisted account states that must stay visible over a merely
    /// credential-healthy live connector status. `missingCredentials` is
    /// excluded on purpose: a present credential supersedes it.
    private static let persistedFailureStates: Set<InboxAccountStatus> = [
        .error, .degraded, .rateLimited, .tokenExpired, .permissionDenied, .missingHelper,
    ]

    /// Syncs one source or all sources. Failures are persisted to the account
    /// row so a transient error stays visible after this call returns.
    /// - Parameter source: Optional source to sync.
    public func sync(source: InboxSource? = nil) async -> [InboxConnectorStatus] {
        var statuses: [InboxConnectorStatus] = []
        for connector in connectors.values where source == nil || connector.source == source {
            let connectorStatus = await connector.status()
            let accountID = connectorStatus.accountID ?? "default"
            let cursor = try? await store.syncCursor(source: connector.source, accountID: accountID)
            do {
                let result = try await connector.sync(cursor: cursor)
                for account in result.accounts { try await store.upsertAccount(account) }
                for thread in result.threads { try await store.upsertThread(thread) }
                try await store.upsertItems(result.items)
                if let nextCursor = result.nextCursor {
                    try await store.setSyncCursor(nextCursor, source: connector.source, accountID: accountID)
                }
                statuses.append(result.status)
                notify(.items)
            } catch {
                let message = Self.userSafeMessage(for: error)
                statuses.append(InboxConnectorStatus(
                    source: connector.source,
                    accountID: accountID,
                    status: .error,
                    message: message,
                    capabilities: connector.capabilities
                ))
                // Persist the failure; otherwise the next status() call
                // recomputes from credentials alone and silently reports the
                // stale healthy state. The store upsert preserves the user's
                // notifications preference.
                try? await store.upsertAccount(InboxAccount(
                    source: connector.source,
                    accountID: accountID,
                    displayName: connectorStatus.displayName ?? connector.source.rawValue,
                    status: .error,
                    statusMessage: message,
                    capabilities: connector.capabilities
                ))
            }
        }
        notify(.accounts)
        return statuses
    }

    /// Connects or records an account, storing token bytes only in Keychain when supplied.
    ///
    /// The UI and CLI use `"default"` as an account-id sentinel. Connectors
    /// read tokens under their canonical account id (Gmail `"me"`, Discord
    /// `"bot"`), so the sentinel is resolved to the connector's id before any
    /// token or account write; otherwise saved tokens would never be read.
    /// - Parameters:
    ///   - source: Source service to connect.
    ///   - accountID: Source account id, or `"default"` to use the connector's canonical id.
    ///   - displayName: Optional display name.
    ///   - token: Optional secret token bytes as a string.
    public func connect(
        source: InboxSource,
        accountID: String = "default",
        displayName: String? = nil,
        token: String? = nil
    ) async throws -> InboxConnectorStatus {
        let connector = connectors[source]
        let resolvedAccountID = await Self.resolvedAccountID(requested: accountID, connector: connector)
        if let token, !token.isEmpty {
            guard let tokenStore else { throw InboxError.connectorUnavailable("No token store configured") }
            try await tokenStore.saveToken(Data(token.utf8), source: source, accountID: resolvedAccountID)
        }
        let capabilities = connector?.capabilities ?? []
        let credentialState = await tokenStore?.credentialState(source: source, accountID: resolvedAccountID) ?? .missing
        let requiresCredential = source == .gmail || source == .slack || source == .discord
        let status: InboxAccountStatus = requiresCredential && credentialState != .present ? .missingCredentials : .connected
        let account = InboxAccount(
            source: source,
            accountID: resolvedAccountID,
            displayName: displayName ?? source.rawValue,
            status: status,
            statusMessage: status == .connected ? nil : "Credential required",
            capabilities: capabilities
        )
        try await store.upsertAccount(account)
        notify(.accounts)
        return InboxConnectorStatus(
            source: source,
            accountID: resolvedAccountID,
            displayName: account.displayName,
            status: status,
            message: account.statusMessage,
            credentialState: credentialState,
            capabilities: capabilities
        )
    }

    /// Disconnects an account and removes its token from Keychain when available.
    /// - Parameters:
    ///   - source: Source service to disconnect.
    ///   - accountID: Source account id, or `"default"` to use the connector's canonical id.
    public func disconnect(source: InboxSource, accountID: String = "default") async throws -> InboxConnectorStatus {
        let connector = connectors[source]
        let resolvedAccountID = await Self.resolvedAccountID(requested: accountID, connector: connector)
        try await tokenStore?.deleteToken(source: source, accountID: resolvedAccountID)
        let capabilities = connector?.capabilities ?? []
        let account = InboxAccount(
            source: source,
            accountID: resolvedAccountID,
            displayName: source.rawValue,
            status: .disconnected,
            statusMessage: nil,
            capabilities: capabilities
        )
        try await store.upsertAccount(account)
        notify(.accounts)
        return InboxConnectorStatus(
            source: source,
            accountID: resolvedAccountID,
            displayName: account.displayName,
            status: .disconnected,
            credentialState: .missing,
            capabilities: capabilities
        )
    }

    /// Maps an error to a user-safe message. ``InboxError`` descriptions are
    /// already user-shaped; anything else becomes a generic connector failure
    /// so raw Swift error dumps never reach persisted or UI-visible fields.
    private static func userSafeMessage(for error: Error) -> String {
        switch error {
        case InboxError.openFailed, InboxError.prepareFailed, InboxError.stepFailed:
            return "Inbox storage error"
        case let error as InboxError:
            return error.description
        default:
            return "Connector request failed"
        }
    }

    /// Maps the `"default"` account-id sentinel to the connector's canonical
    /// account id so token storage and connector token reads share one slot.
    private static func resolvedAccountID(
        requested: String,
        connector: (any InboxConnector)?
    ) async -> String {
        guard requested == "default", let connector else { return requested }
        return await connector.status().accountID ?? requested
    }

    /// Lists local inbox items.
    /// - Parameter query: List query.
    public func list(_ query: InboxListQuery) async throws -> [InboxItem] {
        try await store.list(query)
    }

    /// Searches local inbox items.
    /// - Parameters:
    ///   - query: User-entered search query.
    ///   - limit: Maximum result count.
    public func search(_ query: String, limit: Int = 50) async throws -> [InboxSearchHit] {
        try await store.search(query, limit: limit)
    }

    /// Marks a local item or thread read or unread. The local store is
    /// authoritative; connectors that advertise ``InboxConnectorCapability/markRead``
    /// receive a best-effort remote propagation afterwards.
    public func markRead(itemID: String? = nil, threadID: String? = nil, unread: Bool = false) async throws {
        try await store.markRead(itemID: itemID, threadID: threadID, unread: unread)
        notify(.items)
        await propagateMarkRead(itemID: itemID, threadID: threadID)
    }

    /// Best-effort remote mark-read for capable connectors. Local-first: a
    /// remote failure never rolls back the local state; a later sync
    /// reconciles from the service.
    private func propagateMarkRead(itemID: String?, threadID: String?) async {
        var item: InboxItem?
        if let itemID { item = try? await store.item(id: itemID) }
        guard let resolvedThreadID = threadID ?? item?.threadID,
              let thread = try? await store.thread(id: resolvedThreadID),
              let connector = connectors[thread.source],
              connector.capabilities.contains(.markRead) else { return }
        try? await connector.markRead(thread: thread, item: item)
    }

    /// Creates a local draft using the owning connector when available.
    public func draftReply(threadID: String, instruction: String?) async throws -> InboxDraft {
        guard let thread = try await store.thread(id: threadID) else {
            throw InboxError.notFound("Inbox thread not found")
        }
        let recent = try await store.recentItems(threadID: threadID, limit: 12)
        let body: String
        if let connector = connectors[thread.source] {
            body = try await connector.draftReply(thread: thread, recentItems: recent, instruction: instruction)
        } else {
            body = instruction ?? ""
        }
        let draft = try await store.createDraft(threadID: threadID, instruction: instruction, body: body)
        notify(.items)
        return draft
    }

    /// Sends a draft after explicit user approval.
    public func sendApprovedReply(draftID: String) async throws -> InboxDraft {
        guard var draft = try await store.draft(id: draftID) else {
            throw InboxError.notFound("Inbox draft not found")
        }
        guard let thread = try await store.thread(id: draft.threadID) else {
            throw InboxError.notFound("Inbox thread not found")
        }
        guard let connector = connectors[draft.source] else {
            throw InboxError.connectorUnavailable("No connector for \(draft.source.rawValue)")
        }
        guard connector.capabilities.contains(.sendReply) else {
            throw InboxError.unsupported("\(draft.source.rawValue) does not support replies")
        }
        draft.status = .approved
        draft.approvedAt = Date.now
        try await store.upsertDraft(draft)
        do {
            try await connector.sendApprovedReply(draft: draft, thread: thread)
            draft.status = .sent
            draft.sentAt = Date.now
            draft.errorMessage = nil
        } catch {
            draft.status = .failed
            draft.errorMessage = Self.userSafeMessage(for: error)
        }
        try await store.upsertDraft(draft)
        notify(.items)
        return draft
    }

    /// Pushes a normalized external event into the local inbox.
    public func push(account: InboxAccount, thread: InboxThread, item: InboxItem) async throws {
        try await push(records: [InboxPushRecord(account: account, thread: thread, item: item)])
    }

    /// Pushes a batch of normalized external events with one change
    /// notification, so bulk mirrors (like the Feed mirror's initial load)
    /// trigger a single downstream refresh instead of one per item.
    /// - Parameter records: Events to persist.
    public func push(records: [InboxPushRecord]) async throws {
        guard !records.isEmpty else { return }
        for record in records {
            try await store.upsertAccount(record.account)
            try await store.upsertThread(record.thread)
            try await store.upsertItem(record.item)
        }
        notify(.items)
    }

    /// Returns source unread counts.
    public func unreadCounts() async throws -> [InboxSourceUnreadCount] {
        try await store.unreadCounts()
    }

    /// Returns persisted accounts.
    public func accounts() async throws -> [InboxAccount] {
        try await store.accounts()
    }

    /// Updates the cmux-native notification preference for one account.
    /// - Parameters:
    ///   - source: Source service.
    ///   - accountID: Source account id.
    ///   - enabled: Whether cmux should surface native notifications.
    public func setNotificationsEnabled(
        source: InboxSource,
        accountID: String,
        enabled: Bool
    ) async throws {
        try await store.setNotificationsEnabled(source: source, accountID: accountID, enabled: enabled)
        notify(.accounts)
    }

    /// Returns recent context for a thread.
    public func recentItems(threadID: String, limit: Int = 20) async throws -> [InboxItem] {
        try await store.recentItems(threadID: threadID, limit: limit)
    }

    /// Returns one local thread by id.
    /// - Parameter threadID: Local thread id.
    public func thread(id threadID: String) async throws -> InboxThread? {
        try await store.thread(id: threadID)
    }

    /// Returns local threads by id.
    /// - Parameter threadIDs: Local thread ids to load.
    public func threads(ids threadIDs: [String]) async throws -> [InboxThread] {
        try await store.threads(ids: threadIDs)
    }

    /// Returns one local draft by id.
    /// - Parameter draftID: Local draft id.
    public func draft(id draftID: String) async throws -> InboxDraft? {
        try await store.draft(id: draftID)
    }

    /// Updates the editable body for a local draft before approved send.
    /// - Parameters:
    ///   - draftID: Local draft id.
    ///   - body: Edited reply body.
    public func updateDraftBody(draftID: String, body: String) async throws -> InboxDraft {
        guard var draft = try await store.draft(id: draftID) else {
            throw InboxError.notFound("Inbox draft not found")
        }
        draft.body = body
        draft.status = .editing
        try await store.upsertDraft(draft)
        notify(.items)
        return draft
    }

    private func ingest(_ event: InboxConnectorEvent) async {
        do {
            switch event {
            case .account(let account):
                try await store.upsertAccount(account)
                notify(.accounts)
            case .thread(let thread):
                try await store.upsertThread(thread)
                notify(.items)
            case .item(let item):
                try await store.upsertItem(item)
                notify(.items)
            }
        } catch {
            notify(.accounts)
        }
    }

    private func notify(_ change: InboxChange) {
        for continuation in continuations.values {
            continuation.yield(change)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id]?.finish()
        continuations.removeValue(forKey: id)
    }
}
