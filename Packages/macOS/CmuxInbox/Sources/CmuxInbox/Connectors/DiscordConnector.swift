public import Foundation

/// Discord connector using official bot REST and Gateway payloads only.
public actor DiscordConnector: InboxConnector {
    /// Source service owned by the connector.
    public let source: InboxSource = .discord
    /// Discord supports live Gateway events, REST backfill, replies, and deep links for bot-accessible channels.
    public let capabilities: Set<InboxConnectorCapability> = [.liveEvents, .backfill, .sendReply, .deepLink]

    private let accountID: String
    private let displayName: String
    private let channelIDs: [String]
    private let tokenStore: any InboxTokenStoring
    private let httpClient: any InboxHTTPClient
    private let identity = InboxIdentity()

    // Discord REST timestamps carry fractional seconds; a plain
    // ISO8601DateFormatter never parses them, so keep both cached variants.
    // Actor-isolated instance state because the formatter is not Sendable.
    private let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let plainISOFormatter = ISO8601DateFormatter()

    /// Creates a Discord connector.
    public init(
        accountID: String = "bot",
        displayName: String = "Discord",
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

    /// Returns Discord bot token status without exposing token bytes.
    public func status() async -> InboxConnectorStatus {
        let credentialState = await tokenStore.credentialState(source: .discord, accountID: accountID)
        return InboxConnectorStatus(
            source: .discord,
            accountID: accountID,
            displayName: displayName,
            status: credentialState == .present ? .connected : .missingCredentials,
            message: credentialState == .present ? nil : "Add a Discord bot token in Keychain to enable Discord sync",
            credentialState: credentialState,
            capabilities: capabilities
        )
    }

    /// Backfills selected bot-accessible channels through Discord REST.
    public func sync(cursor: String?) async throws -> InboxConnectorSyncResult {
        guard let tokenData = try await tokenStore.token(source: .discord, accountID: accountID),
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty else {
            let status = await status()
            return InboxConnectorSyncResult(accounts: [account(status: .missingCredentials, message: status.message)], status: status)
        }
        // No configured channels means auto-discovery: every text channel in
        // every guild the bot was invited to. Channels the bot cannot read
        // (403) are skipped, not fatal — partial visibility is normal for bots.
        var channelNames: [String: String] = [:]
        var resolvedChannelIDs = channelIDs
        var discovering = false
        if resolvedChannelIDs.isEmpty {
            discovering = true
            let discovery = try await discoverChannels(token: token)
            if let status = discovery.errorStatus {
                return InboxConnectorSyncResult(accounts: [account(status: status.status, message: status.message)], status: status)
            }
            resolvedChannelIDs = discovery.channels.map(\.id)
            channelNames = Dictionary(uniqueKeysWithValues: discovery.channels.map { ($0.id, $0.title) })
            guard !resolvedChannelIDs.isEmpty else {
                let status = InboxConnectorStatus(
                    source: .discord,
                    accountID: accountID,
                    displayName: displayName,
                    status: .degraded,
                    message: "The Discord bot is not in any servers with text channels yet. Invite it to a server.",
                    credentialState: .present,
                    capabilities: capabilities
                )
                return InboxConnectorSyncResult(accounts: [account(status: .degraded, message: status.message)], status: status)
            }
        }

        var threads: [InboxThread] = []
        var items: [InboxItem] = []
        // Per-channel snowflake high-watermarks; same opaque JSON-map cursor
        // shape as Slack, with the same bounded rotation window per pass.
        var cursors = Self.channelCursors(from: cursor)
        let window = SlackConnector.syncWindow(
            channels: resolvedChannelIDs,
            cursors: cursors,
            after: cursors[Self.rotationKey]
        )
        for channelID in window {
            let after = cursors[channelID].flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
            let response = try await httpClient.data(for: try Self.channelMessagesRequest(token: token, channelID: channelID, after: after))
            if discovering, response.statusCode == 403 {
                // Bot lacks read access here; remember the channel as visited
                // so rotation moves on, and keep syncing the rest.
                cursors[channelID] = cursors[channelID] ?? "0"
                continue
            }
            if let status = statusOverride(from: response) {
                return InboxConnectorSyncResult(accounts: [account(status: status.status, message: status.message)], status: status)
            }
            let parsed = try parseMessages(data: response.data, channelID: channelID, channelName: channelNames[channelID])
            threads.append(contentsOf: parsed.threads)
            items.append(contentsOf: parsed.items)
            if let newest = parsed.newestMessageID {
                cursors[channelID] = newest
            } else {
                cursors[channelID] = cursors[channelID] ?? "0"
            }
        }
        if resolvedChannelIDs.count > SlackConnector.historyFetchesPerSync {
            cursors[Self.rotationKey] = window.last ?? cursors[Self.rotationKey]
        }
        let status = InboxConnectorStatus(
            source: .discord,
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

    // MARK: - Auto-discovery

    static let rotationKey = "__rotation"
    private static let guildScanLimit = 10
    private static let discoveredChannelLimit = 50

    public struct DiscoveredChannel: Equatable, Sendable {
        public let id: String
        public let title: String
    }

    /// Lists guilds the bot belongs to.
    public static func guildsRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://discord.com/api/v10/users/@me/guilds")!)
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Lists channels of one guild.
    public static func guildChannelsRequest(token: String, guildID: String) throws -> URLRequest {
        guard let url = URL(string: "https://discord.com/api/v10/guilds/\(try encodedChannelID(guildID))/channels") else {
            throw InboxError.invalidParameters("Invalid Discord guild id")
        }
        var request = URLRequest(url: url)
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Parses /users/@me/guilds.
    public static func parseGuilds(data: Data) throws -> [(id: String, name: String)] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw InboxError.connectorUnavailable("Discord guild list is unreadable")
        }
        return array.compactMap { raw in
            guard let id = raw["id"] as? String else { return nil }
            return (id, (raw["name"] as? String) ?? id)
        }
    }

    /// Parses /guilds/{id}/channels down to readable text channels (0) and
    /// announcement channels (5).
    public static func parseGuildTextChannels(data: Data, guildName: String) throws -> [DiscoveredChannel] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw InboxError.connectorUnavailable("Discord channel list is unreadable")
        }
        return array.compactMap { raw in
            guard let id = raw["id"] as? String,
                  let type = raw["type"] as? Int, type == 0 || type == 5 else { return nil }
            let name = (raw["name"] as? String) ?? id
            return DiscoveredChannel(id: id, title: "#\(name) · \(guildName)")
        }
    }

    public static func channelCursors(from cursor: String?) -> [String: String] {
        guard let cursor, let data = cursor.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    public static func encodedChannelCursors(_ cursors: [String: String]) -> String? {
        guard !cursors.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cursors) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func discoverChannels(token: String) async throws -> (channels: [DiscoveredChannel], errorStatus: InboxConnectorStatus?) {
        let guildsResponse = try await httpClient.data(for: Self.guildsRequest(token: token))
        if let status = statusOverride(from: guildsResponse) {
            return ([], status)
        }
        let guilds = try Self.parseGuilds(data: guildsResponse.data)
        var channels: [DiscoveredChannel] = []
        for guild in guilds.prefix(Self.guildScanLimit) {
            let response = try await httpClient.data(for: try Self.guildChannelsRequest(token: token, guildID: guild.id))
            if response.statusCode == 403 { continue }
            if let status = statusOverride(from: response) {
                return ([], status)
            }
            channels.append(contentsOf: try Self.parseGuildTextChannels(data: response.data, guildName: guild.name))
            if channels.count >= Self.discoveredChannelLimit { break }
        }
        return (Array(channels.prefix(Self.discoveredChannelLimit)), nil)
    }

    /// Sends a user-approved reply as the configured bot.
    public func sendApprovedReply(draft: InboxDraft, thread: InboxThread) async throws {
        guard let tokenData = try await tokenStore.token(source: .discord, accountID: accountID),
              let token = String(data: tokenData, encoding: .utf8) else {
            throw InboxError.tokenUnavailable(.discord, accountID)
        }
        let request = try Self.createMessageRequest(token: token, draft: draft, thread: thread)
        let response = try await httpClient.data(for: request)
        if let status = statusOverride(from: response), status.status != .connected {
            throw InboxError.connectorUnavailable(status.message ?? "Discord send failed")
        }
    }

    /// Builds a REST request for recent channel messages.
    public static func channelMessagesRequest(token: String, channelID: String, after: String? = nil) throws -> URLRequest {
        guard var components = URLComponents(string: "https://discord.com/api/v10/channels/\(try encodedChannelID(channelID))/messages") else {
            throw InboxError.invalidParameters("Invalid Discord channel id")
        }
        var query = [URLQueryItem(name: "limit", value: "50")]
        // Snowflake watermark: only messages newer than the last ingested one.
        if let after, !after.isEmpty { query.append(URLQueryItem(name: "after", value: after)) }
        components.queryItems = query
        guard let url = components.url else {
            throw InboxError.invalidParameters("Invalid Discord channel id")
        }
        var request = URLRequest(url: url)
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Builds a REST request to create a bot message.
    public static func createMessageRequest(token: String, draft: InboxDraft, thread: InboxThread) throws -> URLRequest {
        guard let channelID = thread.metadata["channel_id"] else {
            throw InboxError.invalidParameters("Discord thread is missing channel_id")
        }
        guard let url = URL(string: "https://discord.com/api/v10/channels/\(try encodedChannelID(channelID))/messages") else {
            throw InboxError.invalidParameters("Invalid Discord channel id")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["content": draft.body]
        if let messageID = thread.metadata["message_id"] {
            body["message_reference"] = ["message_id": messageID, "channel_id": channelID]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Parses a Discord Gateway payload into reconnect state or a message item.
    public func parseGatewayPayload(_ data: Data) throws -> DiscordGatewayEvent {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let op = object["op"] as? Int
        if op == 7 { return .reconnect }
        if op == 9 { return .invalidSession }
        guard op == 0, (object["t"] as? String) == "MESSAGE_CREATE",
              let payload = object["d"] as? [String: Any],
              let item = item(from: payload) else { return .ignored }
        return .message(item)
    }

    private func parseMessages(data: Data, channelID: String, channelName: String? = nil) throws -> (threads: [InboxThread], items: [InboxItem], newestMessageID: String?) {
        let messages = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var threadsByID: [String: InboxThread] = [:]
        var items: [InboxItem] = []
        // Snowflakes are numeric and monotonic; compare numerically so id
        // string length differences never pick a stale watermark.
        let newestMessageID = messages
            .compactMap { $0["id"] as? String }
            .max { (UInt64($0) ?? 0) < (UInt64($1) ?? 0) }
        for message in messages {
            guard let item = item(from: message) else { continue }
            let externalThreadID = item.metadata["thread_id"] ?? item.threadID
            threadsByID[item.threadID] = InboxThread(
                threadID: item.threadID,
                source: .discord,
                accountID: accountID,
                externalThreadID: externalThreadID,
                participants: [item.sender],
                title: channelName ?? "#\(channelID)",
                lastActivityAt: item.timestamp,
                externalURL: item.externalURL,
                metadata: ["channel_id": channelID, "message_id": item.externalMessageID]
            )
            items.append(item)
        }
        return (Array(threadsByID.values), items, newestMessageID)
    }

    private func item(from payload: [String: Any]) -> InboxItem? {
        guard let id = payload["id"] as? String,
              let channelID = payload["channel_id"] as? String else { return nil }
        let threadExternalID = (payload["thread"] as? [String: Any])?["id"] as? String
            ?? payload["thread_id"] as? String
            ?? channelID
        let threadID = identity.threadID(source: .discord, accountID: accountID, externalThreadID: threadExternalID)
        let author = payload["author"] as? [String: Any]
        let sender = (author?["global_name"] as? String) ?? (author?["username"] as? String) ?? "Discord"
        let timestamp = isoDate(payload["timestamp"] as? String) ?? Date.now
        let content = (payload["content"] as? String) ?? ""
        let mentions = payload["mentions"] as? [[String: Any]] ?? []
        let isMention = !mentions.isEmpty || content.contains("@")
        return InboxItem(
            itemID: identity.itemID(source: .discord, accountID: accountID, externalMessageID: "\(channelID):\(id)"),
            threadID: threadID,
            source: .discord,
            accountID: accountID,
            externalMessageID: id,
            sender: InboxParticipant(displayName: sender, address: author?["id"] as? String),
            timestamp: timestamp,
            bodyPreview: content,
            body: content,
            metadata: ["channel_id": channelID, "message_id": id, "thread_id": threadExternalID],
            isUnread: true,
            isActionable: isMention,
            externalURL: "https://discord.com/channels/@me/\(channelID)/\(id)"
        )
    }

    private func statusOverride(from response: InboxHTTPResponse) -> InboxConnectorStatus? {
        if response.statusCode == 401 {
            return InboxConnectorStatus(source: .discord, accountID: accountID, displayName: displayName, status: .tokenExpired, message: "Discord bot token is invalid", credentialState: .present, capabilities: capabilities)
        }
        if response.statusCode == 403 || response.statusCode == 404 {
            return InboxConnectorStatus(source: .discord, accountID: accountID, displayName: displayName, status: .permissionDenied, message: "Discord bot lacks access to the selected channel", credentialState: .present, capabilities: capabilities)
        }
        if response.statusCode == 429 {
            return InboxConnectorStatus(source: .discord, accountID: accountID, displayName: displayName, status: .rateLimited, message: "Discord rate limit", credentialState: .present, capabilities: capabilities)
        }
        // Any other non-2xx must surface as an error; falling through would
        // parse an error body as an empty message list and report success.
        if !(200...299).contains(response.statusCode) {
            return InboxConnectorStatus(source: .discord, accountID: accountID, displayName: displayName, status: .error, message: "Discord request failed (HTTP \(response.statusCode))", credentialState: .present, capabilities: capabilities)
        }
        return nil
    }

    private func account(status: InboxAccountStatus, message: String? = nil, lastSyncAt: Date? = nil) -> InboxAccount {
        InboxAccount(source: .discord, accountID: accountID, displayName: displayName, status: status, statusMessage: message, lastSyncAt: lastSyncAt, capabilities: capabilities)
    }

    /// Percent-encodes a configurable channel id for URL path use so invalid
    /// characters cannot crash force-unwrapped URL construction.
    private static func encodedChannelID(_ channelID: String) throws -> String {
        guard let encoded = channelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw InboxError.invalidParameters("Invalid Discord channel id")
        }
        return encoded
    }

    private func isoDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return fractionalISOFormatter.date(from: raw) ?? plainISOFormatter.date(from: raw)
    }
}
