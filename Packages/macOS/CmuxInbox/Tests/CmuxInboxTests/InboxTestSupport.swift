import Foundation
import CmuxInbox

actor MemoryTokenStore: InboxTokenStoring {
    private var tokens: [String: Data]

    init(tokens: [String: String] = [:]) {
        self.tokens = tokens.mapValues { Data($0.utf8) }
    }

    func saveToken(_ token: Data, source: InboxSource, accountID: String) async throws {
        tokens[key(source: source, accountID: accountID)] = token
    }

    func token(source: InboxSource, accountID: String) async throws -> Data? {
        tokens[key(source: source, accountID: accountID)]
    }

    func deleteToken(source: InboxSource, accountID: String) async throws {
        tokens.removeValue(forKey: key(source: source, accountID: accountID))
    }

    func credentialState(source: InboxSource, accountID: String) async -> InboxCredentialState {
        tokens[key(source: source, accountID: accountID)] == nil ? .missing : .present
    }

    private func key(source: InboxSource, accountID: String) -> String {
        "\(source.rawValue):\(accountID)"
    }
}

actor StubHTTPClient: InboxHTTPClient {
    private var responses: [InboxHTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [InboxHTTPResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> InboxHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw InboxError.connectorUnavailable("No stub HTTP response")
        }
        return responses.removeFirst()
    }

    func requestedURLs() -> [String] {
        requests.map { $0.url?.absoluteString ?? "" }
    }

    func authorizationHeaders() -> [String] {
        requests.map { $0.value(forHTTPHeaderField: "Authorization") ?? "" }
    }
}

actor StubConnector: InboxConnector {
    nonisolated let source: InboxSource
    nonisolated let capabilities: Set<InboxConnectorCapability>
    private let statusValue: InboxConnectorStatus
    private var sentDraftIDs: [String] = []
    private var sentBodies: [String] = []

    init(source: InboxSource, capabilities: Set<InboxConnectorCapability>) {
        self.source = source
        self.capabilities = capabilities
        statusValue = InboxConnectorStatus(
            source: source,
            accountID: "default",
            displayName: source.rawValue,
            status: .connected,
            credentialState: .present,
            capabilities: capabilities
        )
    }

    func status() async -> InboxConnectorStatus {
        statusValue
    }

    func sync(cursor: String?) async throws -> InboxConnectorSyncResult {
        InboxConnectorSyncResult(status: statusValue)
    }

    func draftReply(thread: InboxThread, recentItems: [InboxItem], instruction: String?) async throws -> String {
        instruction ?? "Draft from stub"
    }

    func sendApprovedReply(draft: InboxDraft, thread: InboxThread) async throws {
        sentDraftIDs.append(draft.draftID)
        sentBodies.append(draft.body)
    }

    func sentCount() -> Int {
        sentDraftIDs.count
    }

    func sentBodyList() -> [String] {
        sentBodies
    }
}

struct InboxFixtures {
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    func temporaryDatabaseURL(name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-inbox-tests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("inbox.sqlite3", isDirectory: false)
    }

    func account(
        source: InboxSource = .generic,
        accountID: String = "default",
        status: InboxAccountStatus = .connected,
        capabilities: Set<InboxConnectorCapability> = [.backfill, .sendReply]
    ) -> InboxAccount {
        InboxAccount(
            source: source,
            accountID: accountID,
            displayName: source.rawValue,
            status: status,
            lastSyncAt: date,
            capabilities: capabilities
        )
    }

    func thread(
        source: InboxSource = .generic,
        accountID: String = "default",
        suffix: String = "one",
        title: String = "Inbox thread",
        metadata: [String: String] = [:]
    ) -> InboxThread {
        InboxThread(
            threadID: "\(source.rawValue)-thread-\(suffix)",
            source: source,
            accountID: accountID,
            externalThreadID: "external-\(suffix)",
            participants: [InboxParticipant(displayName: "Sender", address: "sender@example.com")],
            title: title,
            lastActivityAt: date,
            externalURL: "cmux://thread/\(suffix)",
            metadata: metadata
        )
    }

    func item(
        source: InboxSource = .generic,
        accountID: String = "default",
        threadID: String? = nil,
        suffix: String = "one",
        preview: String = "Preview",
        body: String? = "Full body",
        unread: Bool = true,
        actionable: Bool = false
    ) -> InboxItem {
        let resolvedThreadID = threadID ?? "\(source.rawValue)-thread-one"
        return InboxItem(
            itemID: "\(source.rawValue)-item-\(suffix)",
            threadID: resolvedThreadID,
            source: source,
            accountID: accountID,
            externalMessageID: "external-message-\(suffix)",
            sender: InboxParticipant(displayName: "Sender", address: "sender@example.com"),
            timestamp: date.addingTimeInterval(Double(suffix.count)),
            bodyPreview: preview,
            body: body,
            metadata: ["fixture": suffix],
            isUnread: unread,
            isActionable: actionable
        )
    }

    func draft(
        source: InboxSource = .generic,
        threadID: String = "generic-thread-one",
        body: String = "Approved reply",
        status: InboxDraftStatus = .editing
    ) -> InboxDraft {
        InboxDraft(
            draftID: "draft-\(source.rawValue)-\(threadID)",
            threadID: threadID,
            source: source,
            accountID: "default",
            body: body,
            status: status,
            createdAt: date
        )
    }
}
