public import Foundation

/// Slack connector using Web API backfill and Socket Mode-compatible event parsing.
public actor SlackConnector: InboxConnector {
    /// Source service owned by the connector.
    public let source: InboxSource = .slack
    /// Slack supports live events, backfill, replies, and deep links; remote mark-read is not implemented yet.
    public let capabilities: Set<InboxConnectorCapability> = [.liveEvents, .backfill, .sendReply, .deepLink]

    private let accountID: String
    private let displayName: String
    private let channelIDs: [String]
    private let tokenStore: any InboxTokenStoring
    private let httpClient: any InboxHTTPClient
    private let identity = InboxIdentity()

    /// Creates a Slack connector.
    public init(
        accountID: String = "default",
        displayName: String = "Slack",
        channelIDs: [String] = [],
        tokenStore: any InboxTokenStoring,
        httpClient: any InboxHTTPClient
    ) {
        self.accountID = accountID
        self.displayName = displayName
        self.channelIDs = channelIDs
        self.tokenStore = tokenStore
        self.httpClient = httpClient
    }

    /// Returns Slack token status without exposing token bytes.
    public func status() async -> InboxConnectorStatus {
        let credentialState = await tokenStore.credentialState(source: .slack, accountID: accountID)
        let state: InboxAccountStatus = credentialState == .present ? .connected : .missingCredentials
        return InboxConnectorStatus(
            source: .slack,
            accountID: accountID,
            displayName: displayName,
            status: state,
            message: credentialState == .present ? nil : "Add a Slack bot token in Keychain to enable Slack sync",
            credentialState: credentialState,
            capabilities: capabilities
        )
    }

    /// Backfills configured Slack conversations through `conversations.history`.
    public func sync(cursor: String?) async throws -> InboxConnectorSyncResult {
        guard let tokenData = try await tokenStore.token(source: .slack, accountID: accountID),
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty else {
            let status = await status()
            return InboxConnectorSyncResult(accounts: [account(status: .missingCredentials, message: status.message)], status: status)
        }
        // No configured channels means real workspaces get auto-discovery:
        // every conversation the bot user is a member of, IMs included.
        var channelNames: [String: String] = [:]
        var resolvedChannelIDs = channelIDs
        if resolvedChannelIDs.isEmpty {
            let discovery = try await discoverConversations(token: token)
            if let status = discovery.errorStatus {
                return InboxConnectorSyncResult(accounts: [account(status: status.status, message: status.message)], status: status)
            }
            resolvedChannelIDs = discovery.channels.map(\.id)
            channelNames = Dictionary(uniqueKeysWithValues: discovery.channels.map { ($0.id, $0.title) })
            guard !resolvedChannelIDs.isEmpty else {
                let status = InboxConnectorStatus(
                    source: .slack,
                    accountID: accountID,
                    displayName: displayName,
                    status: .degraded,
                    message: "The Slack bot is not in any conversations yet. Invite it to a channel with /invite.",
                    credentialState: .present,
                    capabilities: capabilities
                )
                return InboxConnectorSyncResult(accounts: [account(status: .degraded, message: status.message)], status: status)
            }
        }

        var threads: [InboxThread] = []
        var items: [InboxItem] = []
        // One shared timestamp would skip messages: a fast channel advancing
        // the watermark past a slow channel's history loses the gap, so each
        // channel keeps its own high-watermark inside the opaque cursor.
        var cursors = Self.channelCursors(from: cursor)
        let legacyFloor = Self.legacyGlobalCursor(from: cursor)
        // Slack throttles conversations.history hard for non-Marketplace apps,
        // so each pass backfills a bounded rotating window; never-synced
        // conversations go first and the rotation pointer rides the cursor.
        let window = Self.syncWindow(
            channels: resolvedChannelIDs,
            cursors: cursors,
            after: cursors[Self.rotationKey]
        )
        for channelID in window {
            let channelFloor = cursors[channelID] ?? legacyFloor
            // History pages arrive newest-first; the floor..now interval must
            // fully drain (following response_metadata.next_cursor) before the
            // watermark can advance, or the skipped pages become permanent
            // gaps. Pages per channel per pass stay bounded; an undrained
            // interval keeps its floor and continues on the next pass.
            var channelLatestTS: String?
            var pageCursor: String?
            var drained = false
            for _ in 0..<Self.historyPagesPerChannel {
                let response = try await httpClient.data(for: Self.conversationsHistoryRequest(
                    token: token,
                    channelID: channelID,
                    cursor: channelFloor,
                    pageCursor: pageCursor
                ))
                if let status = statusOverride(from: response) {
                    return InboxConnectorSyncResult(accounts: [account(status: status.status, message: status.message)], status: status)
                }
                let parsed = try parseHistory(data: response.data, channelID: channelID, channelName: channelNames[channelID])
                threads.append(contentsOf: parsed.threads)
                items.append(contentsOf: parsed.items)
                if let latestTS = parsed.latestTS,
                   (Double(latestTS) ?? 0) > (Double(channelLatestTS ?? channelFloor ?? "") ?? 0) {
                    channelLatestTS = latestTS
                }
                guard let nextPage = parsed.nextPageCursor else {
                    drained = true
                    break
                }
                pageCursor = nextPage
            }
            if drained, let channelLatestTS {
                cursors[channelID] = channelLatestTS
            } else {
                // Empty interval, or not fully drained: keep the floor so the
                // next pass resumes; dedupe absorbs any re-fetched page.
                cursors[channelID] = channelFloor ?? "0"
            }
        }
        // Only carry a rotation pointer when rotation is actually in play;
        // small workspaces sync every channel each pass and keep a clean
        // per-channel cursor map.
        if resolvedChannelIDs.count > Self.historyFetchesPerSync {
            cursors[Self.rotationKey] = window.last ?? cursors[Self.rotationKey]
        }
        let status = InboxConnectorStatus(
            source: .slack,
            accountID: accountID,
            displayName: displayName,
            status: .connected,
            credentialState: .present,
            capabilities: capabilities,
            lastSyncAt: Date.now
        )
        return InboxConnectorSyncResult(
            accounts: [account(status: .connected, lastSyncAt: Date.now)],
            threads: threads,
            items: items,
            nextCursor: Self.encodedChannelCursors(cursors) ?? cursor,
            status: status
        )
    }

    /// Decodes the per-channel cursor map. The cursor string is opaque to the
    /// hub and store; non-JSON values are treated as a legacy global floor.
    static func channelCursors(from cursor: String?) -> [String: String] {
        guard let cursor, let data = cursor.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    private static func legacyGlobalCursor(from cursor: String?) -> String? {
        guard let cursor, !cursor.isEmpty, Double(cursor) != nil else { return nil }
        return cursor
    }

    static func encodedChannelCursors(_ cursors: [String: String]) -> String? {
        guard !cursors.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cursors) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Cursor-map key carrying the rotation pointer; never a channel id.
    public static let rotationKey = "__rotation"
    /// Max history fetches per sync pass, sized for Slack's per-minute limits.
    public static let historyFetchesPerSync = 10
    /// Max pagination pages drained per channel per pass before deferring the
    /// rest of the interval to the next pass.
    public static let historyPagesPerChannel = 5
    private static let discoveryPageLimit = 3

    public struct DiscoveredConversation: Equatable, Sendable {
        public let id: String
        public let title: String
    }

    /// Picks this pass's backfill window: never-synced conversations first,
    /// then round-robin continuation after the previous pass's last channel.
    public static func syncWindow(channels: [String], cursors: [String: String], after: String?) -> [String] {
        guard channels.count > historyFetchesPerSync else { return channels }
        let fresh = channels.filter { cursors[$0] == nil }
        if fresh.count >= historyFetchesPerSync { return Array(fresh.prefix(historyFetchesPerSync)) }
        var window = fresh
        let synced = channels.filter { cursors[$0] != nil }
        let start = after.flatMap { synced.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        for offset in 0..<synced.count where window.count < historyFetchesPerSync {
            let candidate = synced[(start + offset) % synced.count]
            if !window.contains(candidate) { window.append(candidate) }
        }
        return window
    }

    /// Lists every conversation the bot user belongs to via `users.conversations`.
    public static func usersConversationsRequest(token: String, cursor: String?) -> URLRequest {
        var components = URLComponents(string: "https://slack.com/api/users.conversations")!
        var query = [
            URLQueryItem(name: "types", value: "public_channel,private_channel,mpim,im"),
            URLQueryItem(name: "exclude_archived", value: "true"),
            URLQueryItem(name: "limit", value: "200"),
        ]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func parseConversationsList(data: Data) throws -> (channels: [DiscoveredConversation], nextCursor: String?) {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (object["ok"] as? Bool) != false else {
            throw InboxError.connectorUnavailable((object["error"] as? String) ?? "Slack API error")
        }
        let channels = ((object["channels"] as? [[String: Any]]) ?? []).compactMap { raw -> DiscoveredConversation? in
            guard let id = raw["id"] as? String else { return nil }
            if let name = raw["name"] as? String, !name.isEmpty {
                return DiscoveredConversation(id: id, title: "#\(name)")
            }
            if (raw["is_im"] as? Bool) == true {
                return DiscoveredConversation(id: id, title: "DM \((raw["user"] as? String) ?? id)")
            }
            return DiscoveredConversation(id: id, title: "#\(id)")
        }
        let next = ((object["response_metadata"] as? [String: Any])?["next_cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (channels, next)
    }

    private func discoverConversations(token: String) async throws -> (channels: [DiscoveredConversation], errorStatus: InboxConnectorStatus?) {
        var channels: [DiscoveredConversation] = []
        var pageCursor: String?
        for _ in 0..<Self.discoveryPageLimit {
            let response = try await httpClient.data(for: Self.usersConversationsRequest(token: token, cursor: pageCursor))
            if let status = statusOverride(from: response) {
                return ([], status)
            }
            let page = try Self.parseConversationsList(data: response.data)
            channels.append(contentsOf: page.channels)
            guard let next = page.nextCursor else { break }
            pageCursor = next
        }
        return (channels, nil)
    }

    /// Sends a user-approved Slack reply through `chat.postMessage`.
    public func sendApprovedReply(draft: InboxDraft, thread: InboxThread) async throws {
        guard let tokenData = try await tokenStore.token(source: .slack, accountID: accountID),
              let token = String(data: tokenData, encoding: .utf8) else {
            throw InboxError.tokenUnavailable(.slack, accountID)
        }
        let request = try Self.chatPostMessageRequest(token: token, draft: draft, thread: thread)
        let response = try await httpClient.data(for: request)
        if let status = statusOverride(from: response), status.status != .connected {
            throw InboxError.connectorUnavailable(status.message ?? "Slack send failed")
        }
        // Slack reports most send failures as HTTP 200 with `ok: false`
        // (channel_not_found, not_in_channel, msg_too_long, ...); success must
        // be confirmed from the API result, not inferred from the transport.
        let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        guard (object?["ok"] as? Bool) == true else {
            throw InboxError.connectorUnavailable((object?["error"] as? String) ?? "Slack send failed")
        }
    }

    /// Builds the Web API history request. The cursor is this channel's
    /// message-timestamp high-watermark passed as `oldest` so each sync
    /// fetches only messages newer than the last one already ingested.
    public static func conversationsHistoryRequest(token: String, channelID: String, cursor: String?, pageCursor: String? = nil) -> URLRequest {
        var components = URLComponents(string: "https://slack.com/api/conversations.history")!
        var query = [URLQueryItem(name: "channel", value: channelID), URLQueryItem(name: "limit", value: "100")]
        if let cursor { query.append(URLQueryItem(name: "oldest", value: cursor)) }
        if let pageCursor, !pageCursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: pageCursor)) }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Builds the Web API send request.
    public static func chatPostMessageRequest(token: String, draft: InboxDraft, thread: InboxThread) throws -> URLRequest {
        guard let channelID = thread.metadata["channel_id"] else {
            throw InboxError.invalidParameters("Slack thread is missing channel_id")
        }
        var request = URLRequest(url: URL(string: "https://slack.com/api/chat.postMessage")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["channel": channelID, "text": draft.body]
        if let threadTS = thread.metadata["thread_ts"] { body["thread_ts"] = threadTS }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Parses a Slack Events/Socket Mode message payload into one inbox item.
    public func itemFromEventPayload(_ data: Data) throws -> InboxItem? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let event = (object["event"] as? [String: Any]) ?? (object["payload"] as? [String: Any]) ?? object
        let eventType = event["type"] as? String
        guard eventType == "message" || eventType == "app_mention",
              let channelID = event["channel"] as? String,
              let ts = event["ts"] as? String else { return nil }
        let threadExternalID = "\(channelID):\((event["thread_ts"] as? String) ?? ts)"
        let threadID = identity.threadID(source: .slack, accountID: accountID, externalThreadID: threadExternalID)
        return InboxItem(
            itemID: identity.itemID(source: .slack, accountID: accountID, externalMessageID: "\(channelID):\(ts)"),
            threadID: threadID,
            source: .slack,
            accountID: accountID,
            externalMessageID: "\(channelID):\(ts)",
            sender: InboxParticipant(displayName: (event["user"] as? String) ?? "Slack"),
            timestamp: Self.dateFromSlackTS(ts),
            bodyPreview: (event["text"] as? String) ?? "",
            body: event["text"] as? String,
            metadata: ["channel_id": channelID, "thread_ts": (event["thread_ts"] as? String) ?? ts],
            isUnread: true,
            isActionable: eventType == "app_mention"
        )
    }

    private func parseHistory(data: Data, channelID: String, channelName: String? = nil) throws -> (threads: [InboxThread], items: [InboxItem], latestTS: String?, nextPageCursor: String?) {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (object["ok"] as? Bool) != false else {
            throw InboxError.connectorUnavailable((object["error"] as? String) ?? "Slack API error")
        }
        let messages = (object["messages"] as? [[String: Any]]) ?? []
        let latestTS = messages.compactMap { $0["ts"] as? String }.max { (Double($0) ?? 0) < (Double($1) ?? 0) }
        let hasMore = (object["has_more"] as? Bool) == true
        let nextPageCursor = hasMore
            ? ((object["response_metadata"] as? [String: Any])?["next_cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            : nil
        var threadsByID: [String: InboxThread] = [:]
        var items: [InboxItem] = []
        for message in messages {
            guard let ts = message["ts"] as? String else { continue }
            let threadTS = (message["thread_ts"] as? String) ?? ts
            let externalThreadID = "\(channelID):\(threadTS)"
            let threadID = identity.threadID(source: .slack, accountID: accountID, externalThreadID: externalThreadID)
            let text = (message["text"] as? String) ?? ""
            threadsByID[threadID] = InboxThread(
                threadID: threadID,
                source: .slack,
                accountID: accountID,
                externalThreadID: externalThreadID,
                participants: [InboxParticipant(displayName: (message["user"] as? String) ?? "Slack")],
                title: channelName ?? "#\(channelID)",
                lastActivityAt: Self.dateFromSlackTS(ts),
                externalURL: nil,
                metadata: ["channel_id": channelID, "thread_ts": threadTS]
            )
            items.append(InboxItem(
                itemID: identity.itemID(source: .slack, accountID: accountID, externalMessageID: "\(channelID):\(ts)"),
                threadID: threadID,
                source: .slack,
                accountID: accountID,
                externalMessageID: "\(channelID):\(ts)",
                sender: InboxParticipant(displayName: (message["user"] as? String) ?? "Slack"),
                timestamp: Self.dateFromSlackTS(ts),
                bodyPreview: text,
                body: text,
                metadata: ["channel_id": channelID, "thread_ts": threadTS],
                isUnread: (message["unread"] as? Bool) ?? true
            ))
        }
        return (Array(threadsByID.values), items, latestTS, nextPageCursor)
    }

    private func statusOverride(from response: InboxHTTPResponse) -> InboxConnectorStatus? {
        if response.statusCode == 429 {
            return InboxConnectorStatus(source: .slack, accountID: accountID, displayName: displayName, status: .rateLimited, message: "Slack rate limit", credentialState: .present, capabilities: capabilities)
        }
        if response.statusCode == 401 {
            return InboxConnectorStatus(source: .slack, accountID: accountID, displayName: displayName, status: .tokenExpired, message: "Slack token expired or revoked", credentialState: .present, capabilities: capabilities)
        }
        if let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
           (object["ok"] as? Bool) == false,
           let error = object["error"] as? String,
           ["invalid_auth", "token_revoked", "account_inactive"].contains(error) {
            return InboxConnectorStatus(source: .slack, accountID: accountID, displayName: displayName, status: .tokenExpired, message: "Slack token expired or revoked", credentialState: .present, capabilities: capabilities)
        }
        // Any other non-2xx must surface as an error; falling through would
        // parse an error body as an empty message list and report success.
        if !(200...299).contains(response.statusCode) {
            return InboxConnectorStatus(source: .slack, accountID: accountID, displayName: displayName, status: .error, message: "Slack request failed (HTTP \(response.statusCode))", credentialState: .present, capabilities: capabilities)
        }
        return nil
    }

    private func account(status: InboxAccountStatus, message: String? = nil, lastSyncAt: Date? = nil) -> InboxAccount {
        InboxAccount(source: .slack, accountID: accountID, displayName: displayName, status: status, statusMessage: message, lastSyncAt: lastSyncAt, capabilities: capabilities)
    }

    private static func dateFromSlackTS(_ ts: String) -> Date {
        Date(timeIntervalSince1970: Double(ts) ?? Date.now.timeIntervalSince1970)
    }
}
