public import Foundation

/// The cloud conversation commands a Home source needs, so the source can be
/// driven by a fake daemon in tests. `CloudConversationClient` is the real one.
public protocol CloudConversationCommands: Sendable {
    /// One page of the account inbox (`cloud-inbox-list`): 200 entries from `cursor` (nil: the first page).
    func inboxList(cursor: String?) async throws -> CloudInboxList
    func snapshot(_ conversation: String, tail: Int) async throws -> CloudConversationSnapshot
    func history(_ conversation: String, before seq: UInt64, limit: Int) async throws -> CloudConversationHistory
    /// `cloud-conversation-thread` (`conversation-thread-v1`).
    func thread(_ conversation: String, root: String, after seq: UInt64, limit: Int) async throws -> ConversationThread
    func op(_ request: CloudConversationOpRequest) async throws -> CloudConversationOpResult
    func subscribeInbox() async throws -> CloudSubscription
    func subscribe(_ conversation: String) async throws -> CloudSubscription
    func unsubscribe(_ conversation: String) async throws
    /// `cloud-conversation-live`: asks the owner for its `run.live` snapshot (it comes as an event).
    func requestLive(_ conversation: String) async throws
    /// `cloud-conversation-run`: the steps of a Cloud Chief's run (nil: no such read).
    func runRows(_ conversation: String, agent: String, run: String) async throws -> ConversationRunRows?
    /// Persisted run summaries of one Chief, including finished runs.
    func runs(_ conversation: String, agent: String, oldestStartedAt: Double) async throws -> [ConversationRunSummary]
    /// Same summary read with the loaded reply keys for this author. The
    /// default preserves lightweight test/fallback endpoints; the real client
    /// uses these keys to decide when it has crossed the visible time window.
    func runs(_ conversation: String, agent: String, oldestStartedAt: Double,
              expectedTurns: Set<String>) async throws -> [ConversationRunSummary]
    /// `cloud-requests-list`: the account's open message requests.
    func messageRequests() async throws -> [CloudMessageRequest]
    /// `cloud-conversation-typing`: the person's typing in a subscribed conversation.
    func typing(_ conversation: String, on: Bool) async throws
    /// `cloud-inbox-op`: the person's own pin or mute of one Cloud conversation
    /// (UserDO `inbox.pin`, `inbox.mute`), with the intent's idempotency key.
    func inboxOp(_ conversation: String, idempotencyKey: String, op: ConversationInboxOpRequest.Op) async throws
    /// `cloud-attachment-upload` (`cloud-attachments-v1`): uploads `attachment`'s bytes from `file`
    /// (and its poster or preview) to a Cloud conversation through the daemon's lease. A hash the
    /// conversation already holds returns the owner's record without sending bytes.
    func uploadAttachment(conversation: String, attachment: ConversationAttachment, file: URL, posterFile: URL?,
                          previewFile: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> StoredConversationAttachment
    /// `cloud-attachment-read` (`cloud-attachments-v1`): reads `variant` of `hash` in a Cloud
    /// conversation into `destination` atomically; returns its mime type.
    func downloadAttachment(conversation: String, hash: String, variant: ConversationAttachmentVariant,
                            to destination: URL) async throws -> String
}

/// Cloud conversations (`cloud-conversations-v1`, plans/cmux-next/home-cloud-proxy.md)
/// over one trusted local daemon connection. The daemon only transports;
/// each call throws `missingCapabilities` on a daemon without the transport.
public struct CloudConversationClient: CloudConversationCommands {
    public let connection: DaemonConnection
    /// Commands that call the cloud answer from a daemon worker thread; the
    /// 2 s control-plane deadline is too short for a Worker round trip. A
    /// timed-out mutation has an unknown outcome and is resent with its key.
    public static let networkTimeout: Duration = .seconds(30)

    /// Returns the strict timestamp cursor for the next summary page. Cloud
    /// pagination has no composite cursor yet, so a non-advancing or invalid
    /// boundary must terminate rather than spin or repeat a page.
    @usableFromInline
    internal static func nextRunsCursor(hasMore: Bool, startedAt: [Double], before: UInt64?) -> UInt64? {
        guard hasMore, let oldest = startedAt.min(), oldest.isFinite, oldest < Double(UInt64.max),
              let next = UInt64(exactly: oldest), before.map({ next < $0 }) ?? true else { return nil }
        return next
    }

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    public static func supported(by connection: DaemonConnection) async -> Bool {
        await connection.identity?.supports(DaemonCapability.cloudConversations.rawValue) == true
    }

    private func require() async throws {
        guard await Self.supported(by: connection) else {
            throw DaemonError.missingCapabilities([DaemonCapability.cloudConversations.rawValue])
        }
    }

    private func network<R: DaemonRequest>(_ request: R) async throws -> R.Response {
        try await require()
        return try await connection.request(request, timeout: Self.networkTimeout)
    }

    private func local<R: DaemonRequest>(_ request: R) async throws -> R.Response {
        try await require()
        return try await connection.request(request)
    }

    public func setSession(_ request: CloudSessionSetRequest) async throws -> CloudSessionState {
        try await local(request)
    }

    public func clearSession() async throws -> CloudSessionState {
        try await local(CloudSessionClearRequest())
    }

    public func sessionStatus() async throws -> CloudSessionState {
        try await local(CloudSessionStatusRequest())
    }

    /// `cloud-selfhost-info`: the daemon asks the self-hosted server its lease names who the person is.
    public func selfHostInfo() async throws -> CloudSelfHostInfo {
        try await network(CloudSelfHostInfoRequest())
    }

    public func inboxList(cursor: String?) async throws -> CloudInboxList {
        try await network(CloudInboxListRequest(limit: CloudInboxListRequest.maxLimit, cursor: cursor))
    }

    public func snapshot(_ conversation: String, tail: Int) async throws -> CloudConversationSnapshot {
        try await network(CloudConversationSnapshotRequest(conversation: conversation, tail: tail))
    }

    public func history(_ conversation: String, before seq: UInt64, limit: Int) async throws -> CloudConversationHistory {
        try await network(CloudConversationHistoryRequest(conversation: conversation, beforeSeq: seq, limit: limit))
    }

    public func thread(_ conversation: String, root: String, after seq: UInt64, limit: Int) async throws -> ConversationThread {
        try await network(CloudConversationThreadRequest(conversation: conversation, root: root, afterSeq: seq, limit: limit))
    }

    public func op(_ request: CloudConversationOpRequest) async throws -> CloudConversationOpResult {
        try await network(request)
    }

    public func subscribeInbox() async throws -> CloudSubscription {
        try await local(CloudInboxSubscribeRequest())
    }

    public func subscribe(_ conversation: String) async throws -> CloudSubscription {
        try await local(CloudConversationSubscribeRequest(conversation: conversation))
    }

    public func unsubscribe(_ conversation: String) async throws {
        _ = try await local(CloudConversationUnsubscribeRequest(conversation: conversation))
    }

    public func requestLive(_ conversation: String) async throws {
        guard await connection.identity?.supports(DaemonCapability.cloudChiefLive.rawValue) == true else { return }
        _ = try await local(CloudConversationLiveRequest(conversation: conversation))
    }

    public func messageRequests() async throws -> [CloudMessageRequest] {
        try await network(CloudMessageRequestsRequest()).requests
    }

    public func typing(_ conversation: String, on: Bool) async throws {
        guard await connection.identity?.supports(DaemonCapability.cloudConversationTyping.rawValue) == true else { return }
        _ = try await local(CloudConversationTypingRequest(conversation: conversation, on: on))
    }

    public func inboxOp(_ conversation: String, idempotencyKey: String, op: ConversationInboxOpRequest.Op) async throws {
        _ = try await network(CloudInboxOpRequest(conversation: conversation, idempotencyKey: idempotencyKey, op: op))
    }

    /// A Cloud upload's `commit` sends every byte to the Cloud owner before it answers.
    static let attachmentCommitTimeout: Duration = .seconds(600)

    /// The Cloud proxy's steps: `begin` and each read reach the Worker, `chunk` stays on the daemon.
    private var attachments: AttachmentTransfer<CloudAttachmentUploadRequest, CloudAttachmentReadRequest> {
        AttachmentTransfer(connection: connection, beginTimeout: Self.networkTimeout, chunkTimeout: ConversationClient.attachmentChunkTimeout,
                           commitTimeout: Self.attachmentCommitTimeout, readTimeout: Self.networkTimeout)
    }

    public func uploadAttachment(conversation: String, attachment: ConversationAttachment, file: URL, posterFile: URL?,
                                 previewFile: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> StoredConversationAttachment {
        try await require()
        return try await attachments.upload(conversation: conversation, attachment: attachment, file: file, posterFile: posterFile,
                                            previewFile: previewFile, progress: progress)
    }

    public func downloadAttachment(conversation: String, hash: String, variant: ConversationAttachmentVariant,
                                   to destination: URL) async throws -> String {
        try await require()
        return try await attachments.download(conversation: conversation, hash: hash, variant: variant, to: destination)
    }

    public func runs(_ conversation: String, agent: String, oldestStartedAt: Double) async throws -> [ConversationRunSummary] {
        try await runs(conversation, agent: agent, oldestStartedAt: oldestStartedAt, expectedTurns: [])
    }

    public func runs(_ conversation: String, agent: String, oldestStartedAt: Double,
                     expectedTurns: Set<String>) async throws -> [ConversationRunSummary] {
        guard await connection.identity?.supports(DaemonCapability.cloudConversationRuns.rawValue) == true else { return [] }
        var result: [ConversationRunSummary] = []
        var before: UInt64?
        var unresolved = expectedTurns
        // A run can start before the visible transcript window and still answer a loaded
        // question. Scan the endpoint's finite history instead of stopping at the oldest
        // message timestamp, then HomeAgentRunWindow filters to loaded anchors. This keeps
        // step hydration bounded to matching runs; the endpoint's documented equal-timestamp
        // limit remains its owner's responsibility.
        // wakeup-allow: every iteration awaits a network request; EOF, a nonadvancing cursor, or cancellation ends pagination.
        while !Task.isCancelled {
            let page = try await network(CloudConversationRunsRequest(conversation: conversation, agent: agent, beforeStartedAt: before))
            result += page.runs
            unresolved.subtract(page.runs.compactMap(\.turn))
            // Once all loaded reply keys are found, the time window bounds the
            // remaining scan. A manual message with no run leaves `unresolved`
            // nonempty and therefore scans the endpoint's finite history.
            let oldest = page.runs.compactMap(\.startedAt).min()
            if unresolved.isEmpty, let oldest, oldest <= oldestStartedAt { break }
            guard let next = Self.nextRunsCursor(hasMore: page.hasMore == true,
                                                 startedAt: page.runs.compactMap(\.startedAt), before: before) else { break }
            before = next
        }
        return result
    }

    public func runRows(_ conversation: String, agent: String, run: String) async throws -> ConversationRunRows? {
        guard await connection.identity?.supports(DaemonCapability.cloudConversationRuns.rawValue) == true else { return nil }
        var all = try await network(CloudConversationRunRequest(conversation: conversation, agent: agent, run: run))
        var cursor: UInt64 = 0
        while all.hasMore == true, !Task.isCancelled, let last = all.steps.compactMap(\.seq).max(), last > cursor {
            cursor = last
            let next = try await network(CloudConversationRunRequest(conversation: conversation, agent: agent, run: run, afterSeq: last))
            all.steps += next.steps
            all.hasMore = next.hasMore
        }
        return all
    }
}

extension CloudConversationCommands {
    public func runs(_ conversation: String, agent: String, oldestStartedAt: Double) async throws -> [ConversationRunSummary] { [] }
    public func runs(_ conversation: String, agent: String, oldestStartedAt: Double,
                     expectedTurns: Set<String>) async throws -> [ConversationRunSummary] {
        try await runs(conversation, agent: agent, oldestStartedAt: oldestStartedAt)
    }
    /// Fakes without message requests: none.
    public func messageRequests() async throws -> [CloudMessageRequest] { [] }

    /// Fakes and daemons without live frames: nothing to ask.
    public func requestLive(_ conversation: String) async throws {}

    /// Fakes and daemons without typing: nothing to send.
    public func typing(_ conversation: String, on: Bool) async throws {}

    /// Fakes without the person's inbox: refused as a daemon without `cloud-inbox-op` would.
    public func inboxOp(_ conversation: String, idempotencyKey: String, op: ConversationInboxOpRequest.Op) async throws {
        throw DaemonError.missingCapabilities([DaemonCapability.conversationInboxState.rawValue])
    }

    /// Fakes and daemons without Cloud attachments.
    public func uploadAttachment(conversation: String, attachment: ConversationAttachment, file: URL, posterFile: URL?,
                                 previewFile: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> StoredConversationAttachment {
        throw DaemonError.missingCapabilities([DaemonCapability.cloudAttachments.rawValue])
    }

    /// Fakes and daemons without Cloud attachments.
    public func downloadAttachment(conversation: String, hash: String, variant: ConversationAttachmentVariant,
                                   to destination: URL) async throws -> String {
        throw DaemonError.missingCapabilities([DaemonCapability.cloudAttachments.rawValue])
    }

    /// Fakes and daemons without run reads.
    public func runRows(_ conversation: String, agent: String, run: String) async throws -> ConversationRunRows? { nil }

    /// Fakes and daemons without the read: the caller falls back to history.
    public func thread(_ conversation: String, root: String, after seq: UInt64, limit: Int) async throws -> ConversationThread {
        throw DaemonError.missingCapabilities([DaemonCapability.conversationThread.rawValue])
    }
}

extension DaemonError {
    /// The stable `reason` of a conversation reject (`details.reason`).
    public var rejectReason: String? {
        guard case .command(_, _, _, let details, _) = self else { return nil }
        return details?["reason"]?.stringValue
    }
}
