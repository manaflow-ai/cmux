import Foundation

// HomeStore's sends that attach link previews: the intent is logged at the
// press, then the previews fill it before it goes to the owner.
extension HomeStore {
    /// Whether the owner of `conversation` takes `link_preview` parts (the
    /// local daemon advertises `link-preview-v1`). A sender sends plain text
    /// to an owner that does not.
    public func acceptsLinkPreviews(in conversation: ConversationID) async -> Bool {
        await source.acceptsLinkPreviews(in: conversation)
    }

    /// Sends `parts` (with `uploads`, as `send(conversation:parts:uploads:key:)`)
    /// as one message whose link previews arrive later. The intent is logged
    /// first, with `parts` as given (the plain text), so the row shows at
    /// once and keeps its place in the conversation's send queue; a quit or
    /// a crash before the previews arrive still sends that text. Then
    /// `attach` returns the parts with link previews filled and the pictures
    /// to upload; they replace the logged op (same key, same position) unless
    /// the send was cancelled meanwhile, and the send goes on as one with
    /// attachments (uploads, then `message.send`). Offline, the previews are
    /// skipped and the text waits like any offline send.
    public func send(conversation: ConversationID, parts: [MessagePart], uploads: [LocalAttachment],
                     key: IdempotencyKey = .make(),
                     attaching attach: @MainActor () async -> (parts: [MessagePart], uploads: [LocalAttachment])) async throws {
        guard !stopped else { throw HomeRejection.ownerUnreachable }
        guard !parts.isEmpty else { throw HomeRejection.invalid("empty_message") }
        guard parts.count <= HomeAttachmentPolicy.maxParts else {
            throw HomeAttachmentError.tooManyParts(limit: HomeAttachmentPolicy.maxParts)
        }
        let op = HomeOp.sendMessage(conversation: conversation, parts: parts.map(Self.normalizedPart))
        let intent = HomeIntent(key: key, op: op)
        guard log.append(intent) else { throw HomeRejection.invalid("duplicate intent") }
        log.setUploading(key, true)
        self.uploads[key] = UploadJob(conversation: conversation, attachments: unique(uploads))
        enqueueSend(key, in: conversation)
        afterLogChange(op)
        guard isOnline else { try queueUploadWhileOffline(key) }
        let attached = await attach()
        // Cancelled while the previews loaded: nothing left to send.
        guard log.entries.contains(where: { $0.intent.key == key }), var job = self.uploads[key] else {
            throw CancellationError()
        }
        let filled = attached.parts.map(Self.normalizedPart)
        if !filled.isEmpty, filled.count <= HomeAttachmentPolicy.maxParts {
            let pictures = unique(attached.uploads).filter { picture in
                (try? HomeAttachmentPolicy.check(mimeType: picture.ref.mimeType, byteCount: picture.ref.byteCount,
                                                 name: picture.ref.name)) != nil
            }
            let filledOp = HomeOp.sendMessage(conversation: conversation, parts: filled)
            log.replaceOp(key, with: filledOp)
            for picture in pictures where !job.attachments.contains(where: { $0.ref.hash == picture.ref.hash }) {
                job.attachments.append(picture)
            }
            self.uploads[key] = job
            afterLogChange(filledOp)
        }
        try await uploadAndSubmit(key)
    }

    /// Unique by hash, in order, with the owner's spelling; each one's local
    /// files registered for the blob cache.
    private func unique(_ attachments: [LocalAttachment]) -> [LocalAttachment] {
        var unique: [LocalAttachment] = []
        for var attachment in attachments where !unique.contains(where: { $0.ref.hash == attachment.ref.hash }) {
            attachment.ref = HomeAttachmentPolicy.normalized(attachment.ref)
            unique.append(attachment)
            localFiles[attachment.ref.hash] = attachment.files
        }
        return unique
    }

    private static func normalizedPart(_ part: MessagePart) -> MessagePart {
        guard case .attachment(let ref) = part else { return part }
        return .attachment(HomeAttachmentPolicy.normalized(ref))
    }
}
