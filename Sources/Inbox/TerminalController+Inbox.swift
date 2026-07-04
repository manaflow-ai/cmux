import CmuxInbox
import Foundation

extension TerminalController {
    nonisolated func v2InboxSocketMethod(_ method: String, params: [String: Any]) async -> V2CallResult {
        switch method {
        case "integrations.status": return await v2IntegrationsStatus(params: params)
        case "integrations.connect": return await v2IntegrationsConnect(params: params)
        case "integrations.disconnect": return await v2IntegrationsDisconnect(params: params)
        case "integrations.sync": return await v2IntegrationsSync(params: params)
        case "inbox.list": return await v2InboxList(params: params)
        case "inbox.search": return await v2InboxSearch(params: params)
        case "inbox.mark_read": return await v2InboxMarkRead(params: params)
        case "inbox.draft_reply": return await v2InboxDraftReply(params: params)
        case "inbox.send_reply": return await v2InboxSendReply(params: params)
        case "inbox.push": return await v2InboxPush(params: params)
        default: return .err(code: "method_not_found", message: "Unknown inbox method", data: nil)
        }
    }

    nonisolated func v2IntegrationsStatus(params _: [String: Any]) async -> V2CallResult {
        guard let hub = await inboxHub() else { return inboxUnavailable() }
        do {
            async let statusesTask = hub.status()
            async let accountsTask = hub.accounts()
            async let countsTask = hub.unreadCounts()
            let statuses = await statusesTask
            let accounts = try await accountsTask
            let counts = try await countsTask
            return .ok([
                "statuses": statuses.map(Self.dictionary(status:)),
                "accounts": accounts.map(Self.dictionary(account:)),
                "unread_counts": counts.map(Self.dictionary(count:)),
            ])
        } catch {
            return inboxError(error)
        }
    }

    nonisolated func v2IntegrationsSync(params: [String: Any]) async -> V2CallResult {
        guard let hub = await inboxHub() else { return inboxUnavailable() }
        guard let source = Self.optionalInboxSource(params["source"]) else {
            return .err(code: "invalid_params", message: "Invalid integration source", data: nil)
        }
        let statuses = await hub.sync(source: source)
        await refreshInboxRuntime(seedNotifications: false)
        return .ok(["statuses": statuses.map(Self.dictionary(status:))])
    }

    nonisolated func v2IntegrationsConnect(params: [String: Any]) async -> V2CallResult {
        guard let hub = await inboxHub() else { return inboxUnavailable() }
        guard let source = Self.requiredInboxSource(params["source"]) else {
            return .err(code: "invalid_params", message: "integrations.connect requires source", data: nil)
        }
        let accountID = Self.string(params["account_id"]) ?? "default"
        let displayName = Self.string(params["display_name"])
        let token = Self.string(params["token"])
        do {
            let status = try await hub.connect(
                source: source,
                accountID: accountID,
                displayName: displayName,
                token: token
            )
            await refreshInboxRuntime(seedNotifications: true)
            return .ok(["status": Self.dictionary(status: status)])
        } catch {
            return inboxError(error)
        }
    }

    nonisolated func v2IntegrationsDisconnect(params: [String: Any]) async -> V2CallResult {
        guard let hub = await inboxHub() else { return inboxUnavailable() }
        guard let source = Self.requiredInboxSource(params["source"]) else {
            return .err(code: "invalid_params", message: "integrations.disconnect requires source", data: nil)
        }
        let accountID = Self.string(params["account_id"]) ?? "default"
        do {
            let status = try await hub.disconnect(source: source, accountID: accountID)
            await refreshInboxRuntime(seedNotifications: true)
            return .ok(["status": Self.dictionary(status: status)])
        } catch {
            return inboxError(error)
        }
    }

    nonisolated func v2InboxList(params: [String: Any]) async -> V2CallResult {
        guard let hub = await inboxHub() else { return inboxUnavailable() }
        guard let source = Self.optionalInboxSource(params["source"]) else {
            return .err(code: "invalid_params", message: "Invalid inbox source", data: nil)
        }
        let filter = Self.listFilter(params: params)
        let limit = Self.int(params["limit"]) ?? 50
        do {
            let items = try await hub.list(InboxListQuery(filter: filter, source: source, limit: limit))
            let threads = try await hub.threads(ids: Array(Set(items.map(\.threadID))))
            return .ok([
                "items": items.map(Self.dictionary(item:)),
                "threads": threads.map(Self.dictionary(thread:)),
            ])
        } catch {
            return inboxError(error)
        }
    }

    nonisolated func v2InboxSearch(params: [String: Any]) async -> V2CallResult {
        guard let hub = await inboxHub() else { return inboxUnavailable() }
        guard let query = Self.string(params["query"]), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "inbox.search requires query", data: nil)
        }
        let limit = Self.int(params["limit"]) ?? 50
        do {
            let hits = try await hub.search(query, limit: limit)
            return .ok(["hits": hits.map(Self.dictionary(hit:))])
        } catch {
            return inboxError(error)
        }
    }

    nonisolated func v2InboxMarkRead(params: [String: Any]) async -> V2CallResult {
        guard let hub = await inboxHub() else { return inboxUnavailable() }
        let itemID = Self.string(params["item_id"])
        let threadID = Self.string(params["thread_id"])
        guard itemID != nil || threadID != nil else {
            return .err(code: "invalid_params", message: "inbox.mark_read requires item_id or thread_id", data: nil)
        }
        do {
            try await hub.markRead(itemID: itemID, threadID: threadID, unread: Self.bool(params["unread"]) ?? false)
            await refreshInboxRuntime(seedNotifications: true)
            return .ok(["updated": true])
        } catch {
            return inboxError(error)
        }
    }

    nonisolated func v2InboxDraftReply(params: [String: Any]) async -> V2CallResult {
        guard let hub = await inboxHub() else { return inboxUnavailable() }
        guard let threadID = Self.string(params["thread_id"]) else {
            return .err(code: "invalid_params", message: "inbox.draft_reply requires thread_id", data: nil)
        }
        do {
            let draft = try await hub.draftReply(threadID: threadID, instruction: Self.string(params["instruction"]))
            await refreshInboxRuntime(seedNotifications: true)
            return .ok(["draft": Self.dictionary(draft: draft)])
        } catch {
            return inboxError(error)
        }
    }

    nonisolated func v2InboxSendReply(params: [String: Any]) async -> V2CallResult {
        guard let hub = await inboxHub() else { return inboxUnavailable() }
        guard let draftID = Self.string(params["draft_id"]) else {
            return .err(code: "invalid_params", message: "inbox.send_reply requires draft_id", data: nil)
        }
        do {
            let draft = try await hub.sendApprovedReply(draftID: draftID)
            await refreshInboxRuntime(seedNotifications: true)
            return .ok(["draft": Self.dictionary(draft: draft)])
        } catch {
            return inboxError(error)
        }
    }

    nonisolated func v2InboxPush(params: [String: Any]) async -> V2CallResult {
        guard let hub = await inboxHub() else { return inboxUnavailable() }
        do {
            let event = try Self.normalizedPushEvent(params: params)
            try await hub.push(account: event.account, thread: event.thread, item: event.item)
            await refreshInboxRuntime(seedNotifications: false)
            return .ok([
                "account": Self.dictionary(account: event.account),
                "thread": Self.dictionary(thread: event.thread),
                "item": Self.dictionary(item: event.item),
            ])
        } catch {
            return inboxError(error)
        }
    }

    private nonisolated func inboxHub() async -> IntegrationHub? { await MainActor.run { InboxRuntimeRegistry.current?.hub } }

    private nonisolated func refreshInboxRuntime(seedNotifications: Bool) async {
        if let runtime = await MainActor.run(body: { InboxRuntimeRegistry.current }) {
            await runtime.refresh(seedNotifications: seedNotifications)
        }
    }

    private nonisolated func inboxUnavailable() -> V2CallResult { .err(code: "unavailable", message: "Inbox runtime is not available", data: nil) }

    private nonisolated func inboxError(_ error: Error) -> V2CallResult {
        if let error = error as? InboxError {
            return .err(code: "inbox_error", message: error.description, data: nil)
        }
        return .err(code: "inbox_error", message: String(describing: error), data: nil)
    }
}

private struct InboxPushEvent {
    let account: InboxAccount
    let thread: InboxThread
    let item: InboxItem
}

private extension TerminalController {
    nonisolated static func normalizedPushEvent(params: [String: Any]) throws -> InboxPushEvent {
        let root = (params["event"] as? [String: Any]) ?? params
        let accountObject = root["account"] as? [String: Any] ?? root
        let threadObject = root["thread"] as? [String: Any] ?? root
        let itemObject = root["item"] as? [String: Any] ?? root
        guard let source = requiredInboxSource(root["source"] ?? accountObject["source"] ?? threadObject["source"] ?? itemObject["source"]) else {
            throw InboxError.invalidParameters("inbox.push requires source")
        }
        let accountID = string(root["account_id"] ?? accountObject["account_id"] ?? itemObject["account_id"]) ?? "default"
        let identity = InboxIdentity()
        let externalThreadID = string(threadObject["external_thread_id"] ?? threadObject["thread_id"] ?? root["external_thread_id"] ?? root["thread_id"]) ?? "default"
        guard let externalMessageID = string(itemObject["external_message_id"] ?? itemObject["message_id"] ?? root["external_message_id"] ?? root["message_id"]) else { throw InboxError.invalidParameters("inbox.push requires external_message_id (or message_id) so retries dedupe instead of duplicating items") }
        let sender = participant(itemObject["sender"] ?? root["sender"]) ?? InboxParticipant(displayName: source.rawValue)
        let timestamp = date(itemObject["timestamp"] ?? itemObject["created_at"] ?? root["timestamp"]) ?? Date.now
        let threadID = string(threadObject["local_thread_id"] ?? threadObject["thread_id"]) ?? identity.threadID(source: source, accountID: accountID, externalThreadID: externalThreadID)
        let itemID = string(itemObject["local_item_id"] ?? itemObject["item_id"]) ?? identity.itemID(source: source, accountID: accountID, externalMessageID: externalMessageID)
        let preview = string(itemObject["body_preview"] ?? itemObject["preview"] ?? root["body_preview"] ?? root["preview"])
            ?? string(itemObject["body"] ?? root["body"])
            ?? ""
        let account = InboxAccount(
            source: source,
            accountID: accountID,
            displayName: string(accountObject["display_name"] ?? accountObject["account_display_name"]) ?? accountID,
            status: .connected,
            statusMessage: string(accountObject["status_message"]),
            capabilities: Set(capabilities(accountObject["capabilities"]))
        )
        let thread = InboxThread(
            threadID: threadID,
            source: source,
            accountID: accountID,
            externalThreadID: externalThreadID,
            participants: participants(threadObject["participants"]) ?? [sender],
            title: string(threadObject["title"] ?? threadObject["display_name"] ?? root["title"]) ?? sender.displayName,
            unreadCount: int(threadObject["unread_count"]) ?? 0,
            lastActivityAt: date(threadObject["last_activity_at"]) ?? timestamp,
            isMuted: bool(threadObject["muted"]) ?? false,
            isPinned: bool(threadObject["pinned"]) ?? false,
            isArchived: bool(threadObject["archived"]) ?? false,
            externalURL: string(threadObject["external_url"] ?? root["external_url"]),
            metadata: metadata(threadObject["metadata"])
        )
        let item = InboxItem(
            itemID: itemID,
            threadID: threadID,
            source: source,
            accountID: accountID,
            externalMessageID: externalMessageID,
            sender: sender,
            timestamp: timestamp,
            bodyPreview: preview,
            body: string(itemObject["body"] ?? root["body"]),
            metadata: metadata(itemObject["metadata"] ?? root["metadata"]),
            isUnread: bool(itemObject["unread"] ?? itemObject["is_unread"] ?? root["unread"]) ?? true,
            isActionable: bool(itemObject["actionable"] ?? itemObject["is_actionable"] ?? root["actionable"]) ?? false,
            draftID: string(itemObject["draft_id"]),
            externalURL: string(itemObject["external_url"] ?? root["external_url"])
        )
        return InboxPushEvent(account: account, thread: thread, item: item)
    }

    nonisolated static func dictionary(account: InboxAccount) -> [String: Any] {
        [
            "id": account.id,
            "source": account.source.rawValue,
            "account_id": account.accountID,
            "display_name": account.displayName,
            "status": account.status.rawValue,
            "status_message": account.statusMessage as Any,
            "last_sync_at": iso(account.lastSyncAt) as Any,
            "capabilities": account.capabilities.map(\.rawValue).sorted(),
            "notifications_enabled": account.notificationsEnabled,
        ].compactNullValues()
    }

    nonisolated static func dictionary(status: InboxConnectorStatus) -> [String: Any] {
        [
            "id": status.id,
            "source": status.source.rawValue,
            "account_id": status.accountID as Any,
            "display_name": status.displayName as Any,
            "status": status.status.rawValue,
            "message": status.message as Any,
            "credential_state": status.credentialState.rawValue,
            "capabilities": status.capabilities.map(\.rawValue).sorted(),
            "last_sync_at": iso(status.lastSyncAt) as Any,
        ].compactNullValues()
    }

    nonisolated static func dictionary(count: InboxSourceUnreadCount) -> [String: Any] {
        [
            "id": count.id,
            "source": count.source.rawValue,
            "account_id": count.accountID as Any,
            "unread_count": count.unreadCount,
            "actionable_count": count.actionableCount,
        ].compactNullValues()
    }

    nonisolated static func dictionary(thread: InboxThread) -> [String: Any] {
        [
            "id": thread.threadID,
            "thread_id": thread.threadID,
            "source": thread.source.rawValue,
            "account_id": thread.accountID,
            "external_thread_id": thread.externalThreadID,
            "participants": thread.participants.map(dictionary(participant:)),
            "title": thread.title,
            "unread_count": thread.unreadCount,
            "last_activity_at": iso(thread.lastActivityAt),
            "muted": thread.isMuted,
            "pinned": thread.isPinned,
            "archived": thread.isArchived,
            "external_url": thread.externalURL as Any,
            "metadata": thread.metadata,
        ].compactNullValues()
    }

    nonisolated static func dictionary(item: InboxItem) -> [String: Any] {
        [
            "id": item.itemID,
            "item_id": item.itemID,
            "thread_id": item.threadID,
            "source": item.source.rawValue,
            "account_id": item.accountID,
            "external_message_id": item.externalMessageID,
            "sender": dictionary(participant: item.sender),
            "timestamp": iso(item.timestamp),
            "body_preview": item.bodyPreview,
            "body": item.body as Any,
            "metadata": item.metadata,
            "unread": item.isUnread,
            "actionable": item.isActionable,
            "draft_id": item.draftID as Any,
            "external_url": item.externalURL as Any,
        ].compactNullValues()
    }

    nonisolated static func dictionary(draft: InboxDraft) -> [String: Any] {
        [
            "id": draft.draftID,
            "draft_id": draft.draftID,
            "thread_id": draft.threadID,
            "source": draft.source.rawValue,
            "account_id": draft.accountID,
            "instruction": draft.instruction as Any,
            "body": draft.body,
            "status": draft.status.rawValue,
            "created_at": iso(draft.createdAt),
            "approved_at": iso(draft.approvedAt) as Any,
            "sent_at": iso(draft.sentAt) as Any,
            "error_message": draft.errorMessage as Any,
        ].compactNullValues()
    }

    nonisolated static func dictionary(hit: InboxSearchHit) -> [String: Any] {
        [
            "item": dictionary(item: hit.item),
            "thread": dictionary(thread: hit.thread),
            "snippet": hit.snippet,
            "rank": hit.rank,
        ]
    }

    nonisolated static func dictionary(participant: InboxParticipant) -> [String: Any] {
        [
            "display_name": participant.displayName,
            "address": participant.address as Any,
        ].compactNullValues()
    }

    nonisolated static func optionalInboxSource(_ value: Any?) -> InboxSource?? {
        guard let value else { return .some(nil) }
        guard let source = requiredInboxSource(value) else { return nil }
        return .some(source)
    }

    nonisolated static func requiredInboxSource(_ value: Any?) -> InboxSource? {
        guard let raw = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        return InboxSource(rawValue: raw)
    }

    nonisolated static func listFilter(params: [String: Any]) -> InboxListFilter {
        if bool(params["unread"]) == true { return .unread }
        if bool(params["actionable"]) == true { return .actionable }
        if let raw = string(params["filter"]), let filter = InboxListFilter(rawValue: raw) {
            return filter
        }
        return .all
    }

    nonisolated static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    nonisolated static func int(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    nonisolated static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y", "on": return true
            case "0", "false", "no", "n", "off": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    // Shared: these serializers run per item per socket call; the formatter is thread-safe.
    nonisolated static let inboxISOFormatter = ISO8601DateFormatter()
    nonisolated static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        if let double = value as? Double { return Date(timeIntervalSince1970: double) }
        guard let raw = string(value) else { return nil }
        if let seconds = Double(raw) { return Date(timeIntervalSince1970: seconds) }
        return inboxISOFormatter.date(from: raw)
    }

    nonisolated static func participant(_ value: Any?) -> InboxParticipant? {
        if let name = string(value) {
            return InboxParticipant(displayName: name)
        }
        guard let object = value as? [String: Any] else { return nil }
        guard let displayName = string(object["display_name"] ?? object["name"] ?? object["sender"]) else { return nil }
        return InboxParticipant(displayName: displayName, address: string(object["address"] ?? object["email"] ?? object["id"]))
    }

    nonisolated static func participants(_ value: Any?) -> [InboxParticipant]? {
        guard let array = value as? [Any] else { return nil }
        let values = array.compactMap(participant)
        return values.isEmpty ? nil : values
    }

    nonisolated static func capabilities(_ value: Any?) -> [InboxConnectorCapability] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { raw in
            string(raw).flatMap(InboxConnectorCapability.init(rawValue:))
        }
    }

    nonisolated static func metadata(_ value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let string = string(value) {
                result[key] = string
            }
        }
        return result
    }

    nonisolated static func iso(_ date: Date?) -> String? { date.map { inboxISOFormatter.string(from: $0) } }
}

private extension Dictionary where Key == String, Value == Any {
    func compactNullValues() -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in self where !(value is NSNull) {
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional, mirror.children.isEmpty {
                continue
            }
            result[key] = value
        }
        return result
    }
}
