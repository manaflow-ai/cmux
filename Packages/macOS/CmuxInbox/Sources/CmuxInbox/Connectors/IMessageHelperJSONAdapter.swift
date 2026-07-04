public import Foundation

/// Parses `cmux-imsg` helper JSON into normalized inbox values.
public struct IMessageHelperJSONAdapter: Sendable {
    /// Creates an adapter.
    public init() {}

    /// Parses helper status JSON.
    /// - Parameter data: Helper JSON bytes.
    public static func status(from data: Data) throws -> IMessageHelperStatus {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return IMessageHelperStatus(
            ok: (object["ok"] as? Bool) ?? false,
            message: object["message"] as? String,
            lastSyncAt: (object["last_sync_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
            permissionDenied: (object["permission_denied"] as? Bool) ?? false,
            helperInstalled: (object["helper_installed"] as? Bool) ?? true
        )
    }

    /// Parses recent/history helper JSON.
    /// - Parameter data: Helper JSON bytes.
    public static func syncResult(from data: Data) throws -> InboxConnectorSyncResult {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let accountID = (object["account_id"] as? String) ?? "local"
        let identity = InboxIdentity()
        let threads = ((object["threads"] as? [[String: Any]]) ?? []).map { raw -> InboxThread in
            let externalThreadID = (raw["thread_id"] as? String) ?? UUID().uuidString
            return InboxThread(
                threadID: identity.threadID(source: .imessage, accountID: accountID, externalThreadID: externalThreadID),
                source: .imessage,
                accountID: accountID,
                externalThreadID: externalThreadID,
                participants: [InboxParticipant(displayName: (raw["display_name"] as? String) ?? "Messages")],
                title: (raw["display_name"] as? String) ?? "Messages",
                lastActivityAt: Date(timeIntervalSince1970: (raw["last_activity_at"] as? Double) ?? Date.now.timeIntervalSince1970),
                externalURL: raw["url"] as? String,
                metadata: ["chat_id": externalThreadID]
            )
        }
        let items = ((object["messages"] as? [[String: Any]]) ?? []).compactMap { raw -> InboxItem? in
            guard let externalThreadID = raw["thread_id"] as? String else { return nil }
            let externalMessageID = (raw["message_id"] as? String) ?? UUID().uuidString
            let threadID = identity.threadID(source: .imessage, accountID: accountID, externalThreadID: externalThreadID)
            return InboxItem(
                itemID: identity.itemID(source: .imessage, accountID: accountID, externalMessageID: externalMessageID),
                threadID: threadID,
                source: .imessage,
                accountID: accountID,
                externalMessageID: externalMessageID,
                sender: InboxParticipant(displayName: (raw["sender"] as? String) ?? "Messages"),
                timestamp: Date(timeIntervalSince1970: (raw["timestamp"] as? Double) ?? Date.now.timeIntervalSince1970),
                bodyPreview: (raw["preview"] as? String) ?? (raw["body"] as? String) ?? "",
                body: raw["body"] as? String,
                metadata: ["chat_id": externalThreadID],
                isUnread: (raw["unread"] as? Bool) ?? true,
                isActionable: (raw["actionable"] as? Bool) ?? false
            )
        }
        let account = InboxAccount(
            source: .imessage,
            accountID: accountID,
            displayName: "Messages",
            status: .connected,
            lastSyncAt: Date.now,
            capabilities: IMessageHelperConnector.defaultCapabilities
        )
        let status = InboxConnectorStatus(
            source: .imessage,
            accountID: accountID,
            displayName: "Messages",
            status: .connected,
            credentialState: .present,
            capabilities: IMessageHelperConnector.defaultCapabilities,
            lastSyncAt: Date.now
        )
        return InboxConnectorSyncResult(
            accounts: [account],
            threads: threads,
            items: items,
            nextCursor: object["cursor"] as? String,
            status: status
        )
    }
}
