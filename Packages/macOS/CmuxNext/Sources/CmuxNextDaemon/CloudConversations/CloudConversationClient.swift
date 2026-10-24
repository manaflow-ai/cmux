public import Foundation

/// The cloud conversation commands a Home source needs, so the source can be
/// driven by a fake daemon in tests. `CloudConversationClient` is the real one.
public protocol CloudConversationCommands: Sendable {
    func inboxList(limit: Int) async throws -> CloudInboxList
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

    public func inboxList(limit: Int) async throws -> CloudInboxList {
        try await network(CloudInboxListRequest(limit: limit))
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

    public func runRows(_ conversation: String, agent: String, run: String) async throws -> ConversationRunRows? {
        guard await connection.identity?.supports(DaemonCapability.cloudConversationRuns.rawValue) == true else { return nil }
        var all = try await network(CloudConversationRunRequest(conversation: conversation, agent: agent, run: run))
        var pages = 1
        while all.hasMore == true, pages < 8, let last = all.steps.compactMap(\.seq).max() {
            let next = try await network(CloudConversationRunRequest(conversation: conversation, agent: agent, run: run, afterSeq: last))
            all.steps += next.steps
            all.hasMore = next.hasMore
            pages += 1
        }
        return all
    }
}

extension CloudConversationCommands {
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
