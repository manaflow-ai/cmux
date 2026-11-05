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

    /// A link preview's picture (LinkPreviews' downloaded file) as an image
    /// record to upload with the send that names it: a JPEG at most
    /// `previewMaxPixel` and `previewMaxBytes` in the blob cache. Throws
    /// when the file is not an image or cannot fit.
    public func prepareLinkPreviewImage(fileURL: URL) async throws -> LocalAttachment {
        await beginPrepare()
        defer { preparing -= 1 }
        let prepared = try await Self.makeLinkPreviewImage(fileURL, root: blobCacheDirectory)
        localFiles[prepared.ref.hash] = prepared.files
        return prepared
    }

    @concurrent
    private nonisolated static func makeLinkPreviewImage(_ fileURL: URL, root: URL) async throws -> LocalAttachment {
        try AttachmentMedia.prepareLinkPreviewImage(fileURL: fileURL, root: root)
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
    /// (`HomeSendState.pendingResend`), and so does a send made while
    /// offline, which fails "Not Delivered" only past `offlineSendDeadline`
    /// like a text send; `cancelSend` stops it
    /// (`CancellationError`). Throws like `perform`, and
    /// `HomeAttachmentError` (nothing logged) for a file the owner would
    /// refuse. `threadRoot` set: the message is a reply in that thread; `parent`: the
    /// message of the thread it answers (HomeOp.sendMessage). Any number of
    /// attachments goes, as `send(conversation:parts:uploads:key:)` sends them.
    public func send(conversation: ConversationID, text: String, attachments: [LocalAttachment],
                     key: IdempotencyKey = .make(), threadRoot: MessageID? = nil, parent: MessageID? = nil) async throws {
        var parts = attachments.map { MessagePart.attachment($0.ref) }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(text)) }
        try await send(conversation: conversation, parts: parts, uploads: attachments, key: key, threadRoot: threadRoot, parent: parent)
    }

    /// Sends `parts` as one message, uploading `uploads` first exactly as
    /// `send(conversation:text:attachments:key:)` does (one pending row at
    /// once, progress, the same queue, retry, resume and cancel rules).
    /// `uploads` holds every blob the parts name that the owner may not have
    /// yet: each attachment part's bytes, and a link preview's picture,
    /// which has no attachment part of its own (an image record the sender
    /// uploads, `prepareLinkPreviewImage`). Attachment parts and link
    /// preview pictures take the owner's stored mime type and byte count.
    ///
    /// Any number of attachments goes: past the owner's parts per message
    /// (``HomeAttachmentPolicy/maxParts``) the parts go as several messages,
    /// consecutive slices in order (``HomeAttachmentPolicy/messageGroups(_:extraParts:)``):
    /// the first has `key`, each later one its own key, and each uploads the
    /// blobs its own parts name (attachments and link preview pictures; the
    /// first also any blob no part names). Every file is checked
    /// before any message is logged, so a refusal gives the whole draft back.
    /// All of them are logged at once, then go strictly one after another:
    /// this call returns when the first commits, and a failed one holds the
    /// rest, in order, until its retry commits. Parts with no attachment at
    /// all stay one message within the limit.
    public func send(conversation: ConversationID, parts: [MessagePart], uploads: [LocalAttachment],
                     key: IdempotencyKey = .make(), threadRoot: MessageID? = nil, parent: MessageID? = nil) async throws {
        guard !stopped else { throw HomeRejection.ownerUnreachable }
        // The owner's spelling and ranges, also for refs built outside prepare.
        let attachments = uploads.map { attachment -> LocalAttachment in
            var attachment = attachment
            attachment.ref = HomeAttachmentPolicy.normalized(attachment.ref)
            return attachment
        }
        let parts = parts.map { part -> MessagePart in
            guard case .attachment(let ref) = part else { return part }
            return .attachment(HomeAttachmentPolicy.normalized(ref))
        }
        guard !parts.isEmpty else { throw HomeRejection.invalid("empty_message") }
        guard parts.count <= HomeAttachmentPolicy.maxParts || !attachments.isEmpty else {
            throw HomeAttachmentError.tooManyParts(limit: HomeAttachmentPolicy.maxParts)
        }
        for attachment in attachments {
            try HomeAttachmentPolicy.check(mimeType: attachment.ref.mimeType, byteCount: attachment.ref.byteCount,
                                           name: attachment.ref.name)
        }
        let groups = HomeAttachmentPolicy.messageGroups(parts, extraParts: 0)
        guard groups.count > 1 else {
            let op = HomeOp.sendMessage(conversation: conversation, parts: parts, threadRoot: threadRoot, parent: parent)
            guard !attachments.isEmpty else {
                try await perform(op, key: key)
                return
            }
            try logAttachmentSend(op, uploads: attachments, key: key, in: conversation)
            guard isOnline else { try queueUploadWhileOffline(key) }
            try await uploadAndSubmit(key)
            return
        }
        let named = Set(parts.compactMap(Self.attachmentHash))
        var keys: [IdempotencyKey] = []
        for (index, group) in groups.enumerated() {
            let hashes = Set(group.compactMap(Self.attachmentHash))
            let files = attachments.filter { hashes.contains($0.ref.hash) || (index == 0 && !named.contains($0.ref.hash)) }
            let groupKey = index == 0 ? key : IdempotencyKey.make()
            let op = HomeOp.sendMessage(conversation: conversation, parts: group, threadRoot: threadRoot, parent: parent)
            try logAttachmentSend(op, uploads: files, key: groupKey, in: conversation)
            keys.append(groupKey)
        }
        // One message at a time: each later one starts when the one before it
        // commits (`advanceSendChain`), so the owner commits them in order; a
        // failure holds the rest until its retry commits (`holdSendChain`).
        // A key the caller reused leaves any older chain that still names it.
        let fresh = Set(keys)
        for index in sendChains.indices.reversed() {
            sendChains[index].removeAll { fresh.contains($0) }
            if sendChains[index].isEmpty { sendChains.remove(at: index) }
        }
        sendChains.append(keys)
        for later in keys.dropFirst() { log.setQueued(later, true) }
        guard isOnline else { try queueUploadWhileOffline(key) }
        try await uploadAndSubmit(key)
    }

    /// The blob a part names: an attachment's, or a link preview's picture
    /// (uploaded with the send that names it); nil for any other part.
    private nonisolated static func attachmentHash(_ part: MessagePart) -> String? {
        switch part {
        case .attachment(let ref): ref.hash
        case .linkPreview(let link): link.image?.hash
        default: nil
        }
    }

    /// Logs `op`, a send whose `uploads` go first, under `key`: its row shows
    /// at once and it takes its place in the conversation's send queue.
    private func logAttachmentSend(_ op: HomeOp, uploads attachments: [LocalAttachment], key: IdempotencyKey,
                                   in conversation: ConversationID) throws {
        let intent = HomeIntent(key: key, op: op)
        guard log.append(intent) else { throw HomeRejection.invalid("duplicate intent") }
        log.setUploading(key, true)
        var unique: [LocalAttachment] = []
        for attachment in attachments where !unique.contains(where: { $0.ref.hash == attachment.ref.hash }) {
            unique.append(attachment)
            localFiles[attachment.ref.hash] = attachment.files
        }
        self.uploads[key] = UploadJob(conversation: conversation, attachments: unique)
        enqueueSend(key, in: conversation)
        afterLogChange(op)
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
    /// `hash` (as the bytes, a poster or preview, or a link preview's image).
    func location(of hash: String, in conversation: ConversationID) -> AttachmentLocation? {
        guard let window = mirror.windows[conversation] else { return nil }
        for message in window.messages.reversed() where !message.isRetracted {
            for (index, part) in message.parts.enumerated() where part.blobHashes.contains(hash) {
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
