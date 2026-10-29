@testable import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

/// A daemon's cloud proxy without a daemon: it answers the reads a Cloud
/// source makes when it connects (an empty inbox, live subscriptions) and
/// records every command the tests look at.
actor FakeCloudDaemon: CloudConversationCommands {
    /// One `cloud-inbox-op` as the daemon received it.
    struct InboxOp: Equatable {
        var conversation: String
        var idempotencyKey: String
        var op: ConversationInboxOpRequest.Op
    }

    /// One `cloud-attachment-upload` as the daemon received it: the declaration and the bytes read from its files.
    struct Upload: Equatable {
        var conversation: String
        var attachment: ConversationAttachment
        var bytes: Data
        var posterBytes: Data?
    }

    private(set) var inboxOps: [InboxOp] = []
    /// `cloud-session-set` requests, in order, and how many `cloud-session-clear`.
    private(set) var sessions: [CloudSessionSetRequest] = []
    private(set) var clears = 0
    /// What `cloud-selfhost-info` answers; nil refuses it as under a bearer lease.
    private var selfHost: CloudSelfHostInfo?

    func answerSelfHost(_ info: CloudSelfHostInfo?) { selfHost = info }
    private(set) var uploads: [Upload] = []
    /// `cloud-attachment-read` calls: conversation, hash and variant.
    private(set) var downloads: [String] = []
    /// The bytes the owner holds per `hash:variant`.
    private var blobs: [String: (bytes: Data, mimeType: String)] = [:]

    func hold(_ bytes: Data, hash: String, variant: ConversationAttachmentVariant = .original, mimeType: String) {
        blobs["\(hash):\(variant.rawValue)"] = (bytes, mimeType)
    }

    func inboxList(limit: Int) async throws -> CloudInboxList { CloudInboxList(entries: []) }

    func snapshot(_ conversation: String, tail: Int) async throws -> CloudConversationSnapshot {
        throw DaemonError.notConnected
    }

    func history(_ conversation: String, before seq: UInt64, limit: Int) async throws -> CloudConversationHistory {
        CloudConversationHistory(messages: [], hasMore: false)
    }

    func op(_ request: CloudConversationOpRequest) async throws -> CloudConversationOpResult {
        throw DaemonError.notConnected
    }

    func subscribeInbox() async throws -> CloudSubscription { CloudSubscription(state: "live") }

    func subscribe(_ conversation: String) async throws -> CloudSubscription {
        CloudSubscription(conversation: conversation, state: "live")
    }

    func unsubscribe(_ conversation: String) async throws {}

    func inboxOp(_ conversation: String, idempotencyKey: String, op: ConversationInboxOpRequest.Op) async throws {
        inboxOps.append(InboxOp(conversation: conversation, idempotencyKey: idempotencyKey, op: op))
    }

    /// Keeps the bytes (the owner's record wins its type: it answers what it stored).
    func uploadAttachment(conversation: String, attachment: ConversationAttachment, file: URL, posterFile: URL?,
                          previewFile: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> StoredConversationAttachment {
        let bytes = try Data(contentsOf: file)
        let poster = try posterFile.map { try Data(contentsOf: $0) }
        uploads.append(Upload(conversation: conversation, attachment: attachment, bytes: bytes, posterBytes: poster))
        hold(bytes, hash: attachment.hash, mimeType: attachment.mimeType)
        progress(1)
        return StoredConversationAttachment(hash: attachment.hash, mimeType: attachment.mimeType, byteCount: bytes.count,
                                            poster: attachment.poster, preview: attachment.preview)
    }

    func downloadAttachment(conversation: String, hash: String, variant: ConversationAttachmentVariant,
                            to destination: URL) async throws -> String {
        downloads.append("\(conversation):\(hash):\(variant.rawValue)")
        guard let blob = blobs["\(hash):\(variant.rawValue)"] else {
            throw DaemonError.command(cmd: "cloud-attachment-read", message: "no such attachment", code: "cloud_conversation_rejected")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.bytes.write(to: destination, options: .atomic)
        return blob.mimeType
    }

    func setSession(_ request: CloudSessionSetRequest) async throws -> CloudSessionState {
        sessions.append(request)
        return CloudSessionState(state: "active", apiBaseURL: request.apiBaseURL, expiresAt: request.expiresAt, auth: request.auth)
    }

    func clearSession() async throws -> CloudSessionState {
        clears += 1
        return CloudSessionState(state: "signed_out")
    }

    func selfHostInfo() async throws -> CloudSelfHostInfo {
        guard let selfHost, sessions.last?.auth == "tailscale" else {
            throw DaemonError.command(cmd: "cloud-selfhost-info", message: "not a self-hosted lease", code: "cloud_conversation_rejected")
        }
        return selfHost
    }
}

// In an extension: listed on the actor itself, the `nonisolated protocol` conformance makes
// swift-frontend 6.3.3 (-default-isolation MainActor) infer `nonisolated` on the actor and reject
// it ("'nonisolated' on an actor's synchronous initializer is invalid").
extension FakeCloudDaemon: CloudLeaseSessions {}
