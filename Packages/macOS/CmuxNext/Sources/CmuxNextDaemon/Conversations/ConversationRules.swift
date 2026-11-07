import CCmuxSdkFFI
import Foundation
import os

/// The conversation client rules every client of the daemon follows the same way (the `cmux` CLI
/// and this app), asked of the cmux SDK (cmux-tui/bindings/rust/src/conversation_rules.rs, golden
/// vectors in its tests/cases/conversation_rules.json) through its C ABI,
/// `cmux_sdk_conversation_rule`: JSON in, JSON out, no connection and no I/O, so any thread may ask.
/// Swift keeps the transport and the files; the pagers' cursors, the upload plan, a run step's
/// tool, a part's plain text, the inbox op values and the page clamp are the SDK's (Leo,
/// 2026-11-06: "ok we need to go all hands on deck here. don't just do baby steps. we can just... do it").
nonisolated struct ConversationRules: Sendable {
    /// Why a rule did not answer: it refused its request (`code` is the rule's: `invalid`,
    /// `poster_needed`, `preview_needed`, `unknown_piece`, `no_progress`), or the call failed.
    enum Failure: Error, Equatable {
        case refused(rule: String, code: String)
        case unanswered(rule: String, status: Int32)
    }

    /// One rule on `request`; its `result` decoded as `Reply`.
    func call<Request: Encodable, Reply: Decodable>(_ rule: String, _ request: Request, as: Reply.Type = Reply.self) throws -> Reply {
        let data = try JSONEncoder().encode(request)
        let reply = try callData(rule, data)
        let envelope = try JSONDecoder().decode(Envelope<Reply>.self, from: reply)
        if let result = envelope.result, envelope.ok { return result }
        throw Failure.refused(rule: rule, code: envelope.error?.code ?? "")
    }

    /// The reply bytes; every buffer the library wrote is freed here.
    private func callData(_ rule: String, _ request: Data) throws -> Data {
        var out = CmuxSdkBytes(ptr: nil, len: 0)
        let status = rule.withCString { op in
            request.withUnsafeBytes { bytes in
                cmux_sdk_conversation_rule(op, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &out)
            }
        }
        defer { cmux_sdk_bytes_free(out) }
        guard status == CMUX_SDK_OK, let pointer = out.ptr else {
            Self.log.fault("conversation rule \(rule, privacy: .public) did not answer: \(status)")
            throw Failure.unanswered(rule: rule, status: status)
        }
        return Data(bytes: pointer, count: out.len)
    }

    private struct Envelope<Result: Decodable>: Decodable {
        struct Refusal: Decodable { var code: String }
        var ok: Bool
        var result: Result?
        var error: Refusal?
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "conversation-rules")
}

// MARK: - The rules the client asks

extension ConversationRules {
    /// A page size the owner accepts: `limit` clamped to 1...500. Unanswered, `limit` as given
    /// (the owner refuses one out of range).
    func clampPage(_ limit: Int) -> Int {
        struct Request: Encodable { var limit: Int }
        struct Reply: Decodable { var limit: Int }
        return (try? call("clamp_page", Request(limit: limit), as: Reply.self).limit) ?? limit
    }

    /// The decoded bytes one attachment read asks for (the daemon's limit).
    func attachmentChunkBytes() throws -> Int {
        struct Policy: Decodable {
            var chunkBytes: Int
            enum CodingKeys: String, CodingKey { case chunkBytes = "attachment_chunk_bytes" }
        }
        return try call("policy", [String: String](), as: Policy.self).chunkBytes
    }

    /// One reply-key lookup of a local `conversation-runs` read.
    struct RunsKeyBatch: Decodable, Sendable {
        var turns: [String]?
        var answers: [String]?
    }

    /// The reply-key lookups of a local summary read, in order: the turns, then (when the daemon
    /// serves `conversation-run-answers-v1`) the answered message ids, each in batches.
    func runsKeyBatches(turns: [String], answers: [String], answersServed: Bool) throws -> [RunsKeyBatch] {
        struct Request: Encodable {
            var turns: [String]
            var answers: [String]
            var answersServed: Bool
            enum CodingKeys: String, CodingKey { case turns, answers, answersServed = "answers_served" }
        }
        struct Reply: Decodable { var batches: [RunsKeyBatch] }
        return try call("runs_key_batches", Request(turns: turns, answers: answers, answersServed: answersServed), as: Reply.self).batches
    }

    /// What a summary read asks for after `runs`: the next `before_started_at` (nil: the read
    /// ends) and, for a Cloud read, the loaded reply keys no run was found for yet.
    struct RunsNext: Decodable, Sendable {
        var before: UInt64?
        var unresolved: [String]
    }

    /// `cloud`: `cloud-conversation-runs`, which reads on past the visible window until every
    /// loaded reply key found its run; otherwise `conversation-runs`, which ends at the window.
    func runsNext(cloud: Bool, runs: [ConversationRunSummary], hasMore: Bool, before: UInt64?,
                  oldestStartedAt: Double, unresolved: [String] = []) throws -> RunsNext {
        struct Request: Encodable {
            var owner: String
            var hasMore: Bool
            var startedAt: [Double]
            var turns: [String]
            var before: UInt64?
            var oldestStartedAt: Double
            var unresolved: [String]
            enum CodingKeys: String, CodingKey {
                case owner, turns, before, unresolved
                case hasMore = "has_more"
                case startedAt = "started_at"
                case oldestStartedAt = "oldest_started_at"
            }
        }
        let request = Request(owner: cloud ? "cloud" : "local", hasMore: hasMore, startedAt: runs.compactMap(\.startedAt),
                              turns: runs.compactMap(\.turn), before: before, oldestStartedAt: oldestStartedAt, unresolved: unresolved)
        return try call("runs_next", request, as: RunsNext.self)
    }

    /// A run's steps pager: the next `after` cursor while the owner has more and it moves; nil ends.
    func runStepsNext(hasMore: Bool, cursor: UInt64, keys: [UInt64]) throws -> UInt64? {
        struct Request: Encodable {
            var hasMore: Bool
            var cursor: UInt64
            var keys: [UInt64]
            enum CodingKeys: String, CodingKey { case cursor, keys, hasMore = "has_more" }
        }
        struct Reply: Decodable { var after: UInt64? }
        return try call("run_steps_next", Request(hasMore: hasMore, cursor: cursor, keys: keys), as: Reply.self).after
    }

    /// The pieces an upload sends after `begin` (each from its own file, in chunks).
    struct UploadPlan: Decodable, Sendable {
        struct Piece: Decodable, Sendable {
            var variant: ConversationAttachmentVariant
            var size: UInt64
            var sentBefore: UInt64
            var chunkCount: UInt64
            enum CodingKeys: String, CodingKey {
                case variant, size
                case sentBefore = "sent_before"
                case chunkCount = "chunk_count"
            }
        }
        var total: UInt64
        var pieces: [Piece]
    }

    /// `needs` nil: the original only. A piece whose poster or preview (or its file) is missing is
    /// refused (`poster_needed`, `preview_needed`).
    func uploadPlan(attachment: ConversationAttachment, needs: [ConversationAttachmentVariant]?,
                    hasPosterFile: Bool, hasPreviewFile: Bool) throws -> UploadPlan {
        struct Request: Encodable {
            var attachment: ConversationAttachment
            var needs: [ConversationAttachmentVariant]?
            var hasPosterFile: Bool
            var hasPreviewFile: Bool
            enum CodingKeys: String, CodingKey {
                case attachment, needs
                case hasPosterFile = "has_poster_file"
                case hasPreviewFile = "has_preview_file"
            }
        }
        let request = Request(attachment: attachment, needs: needs, hasPosterFile: hasPosterFile, hasPreviewFile: hasPreviewFile)
        return try call("upload_plan", request, as: UploadPlan.self)
    }

    /// Chunk `index` of `piece`: where it starts, how long it is, and the upload's progress once it is sent.
    struct UploadChunk: Decodable, Sendable {
        var offset: UInt64
        var length: UInt64
        var progress: Double
    }

    func uploadChunk(_ piece: UploadPlan.Piece, total: UInt64, index: UInt64) throws -> UploadChunk {
        struct Request: Encodable {
            var size: UInt64
            var sentBefore: UInt64
            var total: UInt64
            var index: UInt64
            enum CodingKeys: String, CodingKey { case size, total, index, sentBefore = "sent_before" }
        }
        return try call("upload_chunk", Request(size: piece.size, sentBefore: piece.sentBefore, total: total, index: index),
                        as: UploadChunk.self)
    }

    /// After one chunked read reply: the next offset, or nil when the owner's eof ended the read.
    /// A reply that moves no bytes before eof is refused (`no_progress`).
    func readNext(offset: UInt64, received: Int, eof: Bool) throws -> UInt64? {
        struct Request: Encodable {
            var offset: UInt64
            var received: Int
            var eof: Bool
        }
        struct Reply: Decodable { var offset: UInt64? }
        return try call("read_next", Request(offset: offset, received: received, eof: eof), as: Reply.self).offset
    }

    /// An inbox op's absolute value (`inbox.pin`, `inbox.mark_unread`, `inbox.mute`).
    func inboxOp(_ kind: String, on: Bool, position: UInt64? = nil, until: UInt64? = nil) throws -> ConversationInboxOpRequest.Op {
        struct Request: Encodable {
            var kind: String
            var on: Bool
            var position: UInt64?
            var until: UInt64?
        }
        return try call("inbox_op", Request(kind: kind, on: on, position: position, until: until), as: ConversationInboxOpRequest.Op.self)
    }
}
