import Foundation

// HomeStore's attachments: preparing local files, sending with attachments,
// and fetching blobs (local stand-ins first).
extension HomeStore {
    // MARK: Attachments

    /// Hashes a file (SHA-256, streamed), copies it into the blob cache and
    /// reads its display size, duration and poster frame. Runs off the main
    /// actor (`@concurrent`). Opens a security-scoped URL itself. An image
    /// type the owner refuses (TIFF, HEIF) is converted to PNG or JPEG.
    ///
    /// Location metadata (photo GPS, a video's ISO 6709 location) is removed
    /// before hashing unless `keepLocation`; orientation stays. The host
    /// passes the user's Settings > Home toggle, key
    /// `home.attachments.keepLocation` (default off: strip), owned by the
    /// Home UI lane.
    public func prepareAttachment(fileURL: URL, keepLocation: Bool = false) async throws -> LocalAttachment {
        await beginPrepare()
        defer { preparing -= 1 }
        let root = blobCacheDirectory
        let prepared = try await AttachmentMedia.prepare(fileURL: fileURL, root: root, keepLocation: keepLocation)
        localFiles[prepared.ref.hash] = prepared.files
        return prepared
    }

    /// The same for in-memory bytes (a paste or a drop) of a UTType
    /// identifier, with the same `keepLocation`
    /// (`home.attachments.keepLocation`).
    public func prepareAttachment(data: Data, typeIdentifier: String, keepLocation: Bool = false) async throws -> LocalAttachment {
        await beginPrepare()
        defer { preparing -= 1 }
        let root = blobCacheDirectory
        let prepared = try await AttachmentMedia.prepare(data: data, typeIdentifier: typeIdentifier, root: root,
                                                         keepLocation: keepLocation)
        localFiles[prepared.ref.hash] = prepared.files
        return prepared
    }

    /// Waits for a running prune pass, then counts this prepare until its
    /// files are registered in `localFiles` (the prune's keep set).
    private func beginPrepare() async {
        while let running = pruning { await running.value }
        preparing += 1
    }

    /// Sends text with attachments as one message: one pending intent with
    /// `key`, whose parts are the attachments in order, then the text when
    /// it is not blank. The row shows at once with `attachmentProgress`;
    /// the store uploads every attachment through the source, then submits
    /// `message.send` with the same key, after every earlier send in the
    /// conversation. Each part takes the owner's stored mime type, byte
    /// count and poster first (the first upload of a hash wins). An upload
    /// failure leaves the row "Not Delivered" (retry uploads only what is
    /// missing); a disconnect keeps it sending and resumes on reconnect
    /// (`HomeSendState.pendingResend`); `cancelSend` stops it
    /// (`CancellationError`). Throws like `perform`, and
    /// `HomeAttachmentError` (nothing logged) for a file the owner would
    /// refuse.
    public func send(conversation: ConversationID, text: String, attachments: [LocalAttachment],
                     key: IdempotencyKey = .make()) async throws {
        guard isOnline else { throw HomeRejection.ownerUnreachable }
        // The owner's spelling and ranges, also for refs built outside prepare.
        let attachments = attachments.map { attachment -> LocalAttachment in
            var attachment = attachment
            attachment.ref = HomeAttachmentPolicy.normalized(attachment.ref)
            return attachment
        }
        var parts = attachments.map { MessagePart.attachment($0.ref) }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(text)) }
        guard !parts.isEmpty else { throw HomeRejection.invalid("empty_message") }
        guard parts.count <= HomeAttachmentPolicy.maxParts else {
            throw HomeAttachmentError.tooManyParts(limit: HomeAttachmentPolicy.maxParts)
        }
        for attachment in attachments {
            try HomeAttachmentPolicy.check(mimeType: attachment.ref.mimeType, byteCount: attachment.ref.byteCount,
                                           name: attachment.ref.name)
        }
        let op = HomeOp.sendMessage(conversation: conversation, parts: parts)
        guard !attachments.isEmpty else {
            try await perform(op, key: key)
            return
        }
        let intent = HomeIntent(key: key, op: op)
        guard log.append(intent) else { throw HomeRejection.invalid("duplicate intent") }
        log.setUploading(key, true)
        var unique: [LocalAttachment] = []
        for attachment in attachments where !unique.contains(where: { $0.ref.hash == attachment.ref.hash }) {
            unique.append(attachment)
            localFiles[attachment.ref.hash] = attachment.files
        }
        uploads[key] = UploadJob(conversation: conversation, attachments: unique)
        enqueueSend(key, in: conversation)
        afterLogChange(op)
        try await uploadAndSubmit(key)
    }

    /// A local file holding the variant's bytes: this client's own copy when
    /// it has one, else the source's (which caches). The source needs the
    /// message part that references the hash; this finds it in the loaded
    /// transcript of `conversation` (newest first), the conversation of the
    /// row that shows it. Idempotent and cancel-safe.
    public func fetchAttachment(_ ref: AttachmentRef, variant: AttachmentVariant,
                                in conversation: ConversationID) async throws -> URL {
        if let local = try await localAttachment(ref, variant: variant) { return local }
        guard let location = location(of: ref.hash, in: conversation) else {
            if let standIn = try await localStandIn(ref, variant: variant) { return standIn }
            throw HomeRejection.invalid("attachment_not_loaded")
        }
        return try await source.fetch(ref, at: location, variant: variant)
    }

    /// For a pending row (the source cannot name it yet) whose part took
    /// another device's poster or preview (adoption changed its hash):
    /// this client's own poster frame or preview of the same bytes, or a
    /// local thumbnail at the preview size. Nil when there is none.
    private func localStandIn(_ ref: AttachmentRef, variant: AttachmentVariant) async throws -> URL? {
        guard let files = localFiles[ref.hash], FileManager.default.fileExists(atPath: files.fileURL.path) else { return nil }
        let exists = { (url: URL?) -> URL? in url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
        switch variant {
        case .poster:
            return ref.poster == nil ? nil : exists(files.posterURL)
        case .preview:
            guard ref.preview != nil else { return nil }
            if let preview = exists(files.previewURL) { return preview }
            guard ref.mimeType.hasPrefix("image/") else { return nil }
            return try await Self.localThumbnail(files, ref: ref, maxPixel: HomeAttachmentPolicy.previewMaxPixel)
        case .original, .thumbnail:
            return nil
        }
    }

    /// The same when the caller knows where the attachment appears (a row's
    /// `messageID` and part index, a search hit).
    public func fetchAttachment(_ ref: AttachmentRef, at location: AttachmentLocation,
                                variant: AttachmentVariant) async throws -> URL {
        if let local = try await localAttachment(ref, variant: variant) { return local }
        return try await source.fetch(ref, at: location, variant: variant)
    }

    /// This client's copy, or nil when it has none or the OS purged it (the
    /// caller then fetches from the source).
    private func localAttachment(_ ref: AttachmentRef, variant: AttachmentVariant) async throws -> URL? {
        guard let files = localFiles[ref.hash] else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: files.fileURL.path) else {
            localFiles[ref.hash] = nil
            for id in Array(transcriptVersion.keys) { bumpTranscript(id) }
            return nil
        }
        if let poster = files.posterURL, !fm.fileExists(atPath: poster.path) {
            localFiles[ref.hash]?.posterURL = nil
            localFiles[ref.hash]?.posterHash = nil
            return try await localAttachment(ref, variant: variant)
        }
        if let preview = files.previewURL, !fm.fileExists(atPath: preview.path) {
            localFiles[ref.hash]?.previewURL = nil
            localFiles[ref.hash]?.previewHash = nil
            return try await localAttachment(ref, variant: variant)
        }
        AttachmentMedia.touch(files.fileURL.deletingLastPathComponent())
        switch variant {
        case .original:
            return files.fileURL
        case .thumbnail(let maxPixel):
            return try await Self.localThumbnail(files, ref: ref, maxPixel: maxPixel)
        case .poster:
            guard let wanted = ref.poster else { throw HomeRejection.invalid("no_poster") }
            // The owner may have kept another device's poster for these bytes.
            guard let poster = files.posterURL, files.posterHash == wanted.hash else { return nil }
            return poster
        case .preview:
            guard let wanted = ref.preview else { throw HomeRejection.invalid("no_preview") }
            guard let preview = files.previewURL, files.previewHash == wanted.hash else { return nil }
            return preview
        }
    }

    /// The newest committed message part in `conversation` that references
    /// `hash` (as the bytes or as a video's poster).
    func location(of hash: String, in conversation: ConversationID) -> AttachmentLocation? {
        guard let window = mirror.windows[conversation] else { return nil }
        for message in window.messages.reversed() where !message.isRetracted {
            for (index, part) in message.parts.enumerated() {
                guard case .attachment(let ref) = part,
                      ref.hash == hash || ref.posterHash == hash || ref.preview?.hash == hash else { continue }
                return AttachmentLocation(conversation: conversation, message: message.id, partIndex: index)
            }
        }
        return nil
    }

    @concurrent
    private nonisolated static func localThumbnail(_ files: LocalAttachmentFiles, ref: AttachmentRef,
                                                   maxPixel: Int) async throws -> URL {
        try AttachmentMedia.localThumbnail(of: files, ref: ref, maxPixel: maxPixel)
    }
}
