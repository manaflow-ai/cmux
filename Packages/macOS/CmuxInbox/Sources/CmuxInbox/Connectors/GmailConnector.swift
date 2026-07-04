public import Foundation

/// Gmail connector using Gmail API polling/history and optional push-relay cursors.
public actor GmailConnector: InboxConnector {
    /// Source service owned by the connector.
    public let source: InboxSource = .gmail
    /// Gmail supports backfill, mark-read shape, approved replies, and web deep links.
    public let capabilities: Set<InboxConnectorCapability> = [.backfill, .markRead, .sendReply, .deepLink]

    private let accountID: String
    private let displayName: String
    private let tokenStore: any InboxTokenStoring
    private let httpClient: any InboxHTTPClient
    private let identity = InboxIdentity()

    /// Creates a Gmail connector.
    public init(
        accountID: String = "me",
        displayName: String = "Gmail",
        tokenStore: any InboxTokenStoring,
        httpClient: any InboxHTTPClient
    ) {
        self.accountID = accountID
        self.displayName = displayName
        self.tokenStore = tokenStore
        self.httpClient = httpClient
    }

    /// Returns Gmail token status without exposing token bytes.
    public func status() async -> InboxConnectorStatus {
        let credentialState = await tokenStore.credentialState(source: .gmail, accountID: accountID)
        return InboxConnectorStatus(
            source: .gmail,
            accountID: accountID,
            displayName: displayName,
            status: credentialState == .present ? .connected : .missingCredentials,
            message: credentialState == .present ? nil : "Add a Gmail OAuth token in Keychain to enable Gmail sync",
            credentialState: credentialState,
            capabilities: capabilities
        )
    }

    /// Polls Gmail history when a cursor exists, otherwise fetches recent unread messages.
    public func sync(cursor: String?) async throws -> InboxConnectorSyncResult {
        guard let tokenData = try await tokenStore.token(source: .gmail, accountID: accountID),
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty else {
            let status = await status()
            return InboxConnectorSyncResult(accounts: [account(status: .missingCredentials, message: status.message)], status: status)
        }
        let ids: [String]
        let nextCursor: String?
        if let cursor, !cursor.isEmpty {
            let response = try await httpClient.data(for: Self.historyRequest(token: token, accountID: accountID, startHistoryID: cursor))
            if let status = statusOverride(from: response) {
                return InboxConnectorSyncResult(accounts: [account(status: status.status, message: status.message)], status: status)
            }
            let parsed = try parseHistoryIDs(data: response.data)
            ids = parsed.messageIDs
            nextCursor = parsed.historyID ?? cursor
        } else {
            let response = try await httpClient.data(for: Self.listMessagesRequest(token: token, accountID: accountID))
            if let status = statusOverride(from: response) {
                return InboxConnectorSyncResult(accounts: [account(status: status.status, message: status.message)], status: status)
            }
            let parsed = try parseMessageList(data: response.data)
            ids = parsed.messageIDs
            nextCursor = parsed.historyID
        }

        var threads: [InboxThread] = []
        var items: [InboxItem] = []
        for id in ids {
            let response = try await httpClient.data(for: Self.getMessageRequest(token: token, accountID: accountID, messageID: id))
            if let parsed = try parseMessage(data: response.data) {
                threads.append(parsed.thread)
                items.append(parsed.item)
            }
        }
        let status = InboxConnectorStatus(
            source: .gmail,
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
            nextCursor: nextCursor,
            status: status
        )
    }

    /// Converts a push relay payload into the next history cursor.
    public func cursor(from relay: GmailPushRelayPayload) throws -> String {
        guard relay.accountID == accountID else {
            throw InboxError.invalidParameters("Gmail relay account does not match connector account")
        }
        return relay.historyID
    }

    /// Sends a user-approved reply through `users.messages.send`.
    public func sendApprovedReply(draft: InboxDraft, thread: InboxThread) async throws {
        guard let tokenData = try await tokenStore.token(source: .gmail, accountID: accountID),
              let token = String(data: tokenData, encoding: .utf8) else {
            throw InboxError.tokenUnavailable(.gmail, accountID)
        }
        let request = try Self.sendMessageRequest(token: token, accountID: accountID, draft: draft, thread: thread)
        let response = try await httpClient.data(for: request)
        if let status = statusOverride(from: response), status.status != .connected {
            throw InboxError.connectorUnavailable(status.message ?? "Gmail send failed")
        }
    }

    /// Builds a Gmail history request.
    public static func historyRequest(token: String, accountID: String, startHistoryID: String) -> URLRequest {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/\(accountID)/history")!
        components.queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryID),
            URLQueryItem(name: "historyTypes", value: "messageAdded"),
            URLQueryItem(name: "historyTypes", value: "labelAdded"),
            URLQueryItem(name: "historyTypes", value: "labelRemoved"),
        ]
        return authorizedRequest(url: components.url!, token: token)
    }

    /// Builds a Gmail recent unread messages request.
    public static func listMessagesRequest(token: String, accountID: String) -> URLRequest {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/\(accountID)/messages")!
        components.queryItems = [
            URLQueryItem(name: "labelIds", value: "INBOX"),
            URLQueryItem(name: "q", value: "is:unread"),
            URLQueryItem(name: "maxResults", value: "25"),
        ]
        return authorizedRequest(url: components.url!, token: token)
    }

    /// Builds a Gmail message details request.
    public static func getMessageRequest(token: String, accountID: String, messageID: String) -> URLRequest {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/\(accountID)/messages/\(messageID)")!
        components.queryItems = [URLQueryItem(name: "format", value: "metadata")]
        return authorizedRequest(url: components.url!, token: token)
    }

    /// Builds a Gmail send request for an approved reply.
    public static func sendMessageRequest(token: String, accountID: String, draft: InboxDraft, thread: InboxThread) throws -> URLRequest {
        var request = authorizedRequest(
            url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/\(accountID)/messages/send")!,
            token: token
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let to = thread.participants.first?.address ?? ""
        let subject = thread.title
        let raw = "To: \(to)\r\nSubject: Re: \(subject)\r\n\r\n\(draft.body)"
        let body: [String: Any] = [
            "threadId": thread.externalThreadID,
            "raw": base64URL(Data(raw.utf8)),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func parseMessageList(data: Data) throws -> (messageIDs: [String], historyID: String?) {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let ids = ((object["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        return (ids, object["historyId"] as? String)
    }

    private func parseHistoryIDs(data: Data) throws -> (messageIDs: [String], historyID: String?) {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var ids: [String] = []
        for history in (object["history"] as? [[String: Any]]) ?? [] {
            for added in (history["messagesAdded"] as? [[String: Any]]) ?? [] {
                if let message = added["message"] as? [String: Any], let id = message["id"] as? String {
                    ids.append(id)
                }
            }
        }
        return (Array(Set(ids)), object["historyId"] as? String)
    }

    private func parseMessage(data: Data) throws -> (thread: InboxThread, item: InboxItem)? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let id = object["id"] as? String, let threadExternalID = object["threadId"] as? String else { return nil }
        let headers = (((object["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? [])
            .reduce(into: [String: String]()) { result, header in
                guard let name = header["name"] as? String, let value = header["value"] as? String else { return }
                result[name.lowercased()] = value
            }
        let threadID = identity.threadID(source: .gmail, accountID: accountID, externalThreadID: threadExternalID)
        let timestamp = Date(timeIntervalSince1970: ((object["internalDate"] as? String).flatMap(Double.init) ?? Date.now.timeIntervalSince1970 * 1000) / 1000)
        let labels = object["labelIds"] as? [String] ?? []
        let sender = headers["from"] ?? "Gmail"
        let subject = headers["subject"] ?? "Gmail"
        let preview = (object["snippet"] as? String) ?? subject
        let thread = InboxThread(
            threadID: threadID,
            source: .gmail,
            accountID: accountID,
            externalThreadID: threadExternalID,
            participants: [InboxParticipant(displayName: sender, address: sender)],
            title: subject,
            lastActivityAt: timestamp,
            externalURL: "https://mail.google.com/mail/u/\(accountID)/#inbox/\(threadExternalID)",
            metadata: ["gmail_thread_id": threadExternalID]
        )
        let item = InboxItem(
            itemID: identity.itemID(source: .gmail, accountID: accountID, externalMessageID: id),
            threadID: threadID,
            source: .gmail,
            accountID: accountID,
            externalMessageID: id,
            sender: InboxParticipant(displayName: sender, address: sender),
            timestamp: timestamp,
            bodyPreview: preview,
            body: preview,
            metadata: ["gmail_message_id": id],
            isUnread: labels.contains("UNREAD")
        )
        return (thread, item)
    }

    private func statusOverride(from response: InboxHTTPResponse) -> InboxConnectorStatus? {
        if response.statusCode == 401 || response.statusCode == 403 {
            return InboxConnectorStatus(source: .gmail, accountID: accountID, displayName: displayName, status: .tokenExpired, message: "Gmail token expired or lacks required scopes", credentialState: .present, capabilities: capabilities)
        }
        if response.statusCode == 429 {
            return InboxConnectorStatus(source: .gmail, accountID: accountID, displayName: displayName, status: .rateLimited, message: "Gmail rate limit", credentialState: .present, capabilities: capabilities)
        }
        if response.statusCode == 404 {
            return InboxConnectorStatus(source: .gmail, accountID: accountID, displayName: displayName, status: .degraded, message: "Gmail history cursor expired; run a full sync", credentialState: .present, capabilities: capabilities)
        }
        return nil
    }

    private func account(status: InboxAccountStatus, message: String? = nil, lastSyncAt: Date? = nil) -> InboxAccount {
        InboxAccount(source: .gmail, accountID: accountID, displayName: displayName, status: status, statusMessage: message, lastSyncAt: lastSyncAt, capabilities: capabilities)
    }

    private static func authorizedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
