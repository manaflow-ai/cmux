public import CmuxHomeCore
public import Foundation

// Reads: pages, threads, search and attachments.
extension ChiefConversationOwner {
    /// The account inbox: every conversation.
    public func inbox() -> InboxSnapshot { inboxSnapshot() }

    /// The newest `tail` messages of a conversation with its summary and thread stats.
    ///
    /// - Throws: ``HomeRejection/invalid(_:)`` for an unknown conversation.
    public func snapshot(of id: ConversationID, tail: Int) throws -> ConversationPage {
        let state = try conversationState(id)
        let last = state.summary.lastSeq
        let first = last >= Seq(max(tail, 1)) ? last - Seq(max(tail, 1)) + 1 : 1
        let messages = state.messages(from: first, through: last)
        return ConversationPage(conversation: state.summary, messages: messages, threads: state.threadSummaries(in: messages))
    }

    /// The newest `tail` messages of a conversation, without calculating thread summaries.
    /// Use this for list previews that only need message bodies.
    ///
    /// - Throws: ``HomeRejection/invalid(_:)`` for an unknown conversation.
    public func previewMessages(of id: ConversationID, tail: Int) throws -> [Message] {
        let state = try conversationState(id)
        let last = state.summary.lastSeq
        let first = last >= Seq(max(tail, 1)) ? last - Seq(max(tail, 1)) + 1 : 1
        return state.messages(from: first, through: last)
    }

    /// Up to `limit` messages before `beforeSeq`, ascending, with thread stats of the roots among them.
    ///
    /// - Throws: ``HomeRejection/invalid(_:)`` for an unknown conversation.
    public func historyPage(of id: ConversationID, before beforeSeq: Seq, limit: Int) throws -> HistoryPage {
        let state = try conversationState(id)
        guard beforeSeq > 1, limit > 0 else { return HistoryPage(messages: []) }
        let last = min(beforeSeq - 1, state.summary.lastSeq)
        let first = last >= Seq(limit) ? last - Seq(limit) + 1 : 1
        let messages = state.messages(from: first, through: last)
        return HistoryPage(messages: messages, threads: state.threadSummaries(in: messages))
    }

    /// The root and up to `limit` replies after `afterSeq` of one thread, with
    /// the stats of the whole thread.
    ///
    /// - Throws: ``HomeRejection/invalid(_:)`` when `root` is not a thread root here.
    public func thread(of id: ConversationID, root: MessageID, after afterSeq: Seq, limit: Int) throws -> ThreadPage {
        let state = try conversationState(id)
        guard let rootMessage = state.message(root), rootMessage.threadRoot == nil else {
            throw HomeRejection.invalid("unknown_message")
        }
        let replies = state.replies(to: root)
        let after = replies.filter { $0.seq > afterSeq }
        let bounded = Array(after.prefix(max(limit, 1)))
        return ThreadPage(root: rootMessage, replies: bounded, hasMore: after.count > bounded.count,
                          summary: ThreadSummary(root: root, replies: replies))
    }

    /// Case-insensitive substring search over every message, newest first.
    public func search(_ query: String, limit: Int) -> [HomeSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var hits: [HomeSearchHit] = []
        for state in conversations.values.sorted(by: { $0.summary.updatedAt > $1.summary.updatedAt }) {
            for message in state.messages.reversed() where !message.isRetracted {
                let text = message.plainText
                guard let range = text.range(of: needle, options: .caseInsensitive) else { continue }
                let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.utf16.distance(from: range.lowerBound, to: range.upperBound)
                hits.append(HomeSearchHit(conversation: state.id, message: message, highlights: [start..<(start + length)]))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Stores an attachment's bytes (and its poster and preview) under their
    /// SHA-256 in `blobs/`. Idempotent by hash.
    ///
    /// - Throws: ``HomeRejection/invalid(_:)`` when the conversation is unknown
    ///   or a file's hash differs from the ref's.
    public func upload(_ file: AttachmentUpload) throws -> AttachmentRef {
        _ = try conversationState(file.conversation)
        if let poster = file.ref.poster {
            guard let posterURL = file.posterURL else { throw HomeRejection.invalid("poster_missing") }
            try blobs.store(posterURL, hash: poster.hash, mimeType: poster.mimeType)
        }
        if let preview = file.ref.preview {
            guard let previewURL = file.previewURL else { throw HomeRejection.invalid("preview_missing") }
            try blobs.store(previewURL, hash: preview.hash, mimeType: preview.mimeType)
        }
        file.progress(0.5)
        try blobs.store(file.fileURL, hash: file.ref.hash, mimeType: file.ref.mimeType)
        file.progress(1)
        return file.ref
    }

    /// A local file with the variant's bytes. Thumbnails are made once and cached.
    ///
    /// - Throws: ``HomeRejection/invalid(_:)`` (`unknown_blob`, `no_poster`,
    ///   `no_preview`, `no_thumbnail`) when the bytes are not here.
    public func fetch(_ ref: AttachmentRef, variant: AttachmentVariant) throws -> URL {
        switch variant {
        case .original:
            guard let file = blobs.file(ref.hash) else { throw HomeRejection.invalid("unknown_blob") }
            return file
        case .poster:
            guard let poster = ref.poster, let file = blobs.file(poster.hash) else { throw HomeRejection.invalid("no_poster") }
            return file
        case .preview:
            guard let preview = ref.preview, let file = blobs.file(preview.hash) else { throw HomeRejection.invalid("no_preview") }
            return file
        case .thumbnail(let maxPixel):
            let candidate: URL?
            if ref.mimeType.lowercased().hasPrefix("image/") {
                candidate = blobs.file(ref.hash)
            } else {
                candidate = ref.poster.flatMap { blobs.file($0.hash) }
            }
            guard let image = candidate else { throw HomeRejection.invalid("no_thumbnail") }
            return try blobs.thumbnail(of: image, hash: ref.hash, maxPixel: maxPixel)
        }
    }
}
