import Foundation

// HomeStore's attachment upload pipeline: upload passes, the per-conversation
// send queue, resuming interrupted uploads, and re-uploads after a sweep.
extension HomeStore {
    /// Uploads the missing attachments of a logged send, then submits it.
    /// An interrupted upload (`ownerUnreachable`, `indeterminate`) keeps
    /// the row "sending" like a text send without an answer: it uploads
    /// again at once when the connection stayed up (once), else on the next
    /// reconnect, and throws `HomeSendState.pendingResend`. An
    /// `unknown_attachment` refusal (the owner swept the upload before the
    /// send arrived) uploads everything again and resends once under a new
    /// key; a second one leaves the row "Not Delivered". Throws
    /// `CancellationError` when `cancelSend` stopped it or its conversation
    /// left the inbox, and `HomeSendState.unanswered` when its upload
    /// resends ran out.
    /// A pass nobody awaits (`background`: a resume on reconnect or after
    /// a backoff) reports a refusal through `onRefusal`.
    func uploadAndSubmit(_ first: IdempotencyKey, background: Bool = false) async throws {
        var key = first
        do {
            try await uploadAndSubmitPasses(&key)
        } catch let rejection as HomeRejection {
            if background, let entry = log.entries.first(where: { $0.intent.key == key }), case .failed = entry.state {
                reportRefusal(entry.intent, rejection)
            }
            throw rejection
        }
    }

    private func uploadAndSubmitPasses(_ key: inout IdempotencyKey) async throws {
        var uploadedAgain = uploads[key]?.uploadedAfterSweep ?? false
        while true {
            // One pass at a time per send (a reconnect may race a retry).
            guard var job = uploads[key], job.task == nil else { return }
            job.attempt += 1
            job.waitingForReconnect = false
            job.active = true
            let uploaded = job.uploaded
            job.progress = Dictionary(uniqueKeysWithValues: job.attachments.map {
                ($0.ref.hash, uploaded.contains($0.ref.hash) ? 1.0 : 0.0)
            })
            let attempt = job.attempt
            let passKey = key
            let task = Task { [weak self] () -> HomeRejection? in
                await self?.uploadMissing(of: passKey, attempt: attempt)
            }
            job.task = task
            uploads[key] = job
            bumpTranscript(job.conversation)

            let failure = await task.value
            guard let entry = log.entries.first(where: { $0.intent.key == key }), uploads[key]?.attempt == attempt else {
                if !log.entries.contains(where: { $0.intent.key == key }) { uploads[key] = nil }
                throw CancellationError()
            }
            uploads[key]?.task = nil
            uploads[key]?.active = false
            uploads[key]?.progress = [:]
            if let failure {
                if failure == .ownerUnreachable || failure == .indeterminate {
                    if isOnline, uploads[key]?.resumedImmediately == false {
                        uploads[key]?.resumedImmediately = true
                        continue
                    }
                    uploads[key]?.waitingForReconnect = true
                    if isOnline, !scheduleBackoff(key, .upload) {
                        giveUp(key, failure, reachedOwner: uploads[key]?.reachedOwner ?? false)
                        throw HomeSendState.unanswered
                    }
                    afterLogChange(entry.intent.op)
                    throw HomeSendState.pendingResend
                }
                log.setUploading(key, false)
                log.fail(key, failure)
                leaveSendQueue(key)
                afterLogChange(entry.intent.op)
                throw failure
            }
            // The owner keeps the first record of a hash: send its mime type,
            // byte count and poster (or none), or it refuses attachment_mismatch.
            // The logged intent changes first, so the pending row shows the
            // parts that are sent.
            let op = Self.adopting(uploads[key]?.stored ?? [:], in: entry.intent.op)
            if op != entry.intent.op { log.replaceOp(key, with: op) }
            log.setUploading(key, false)
            afterLogChange(op)
            await waitForTurn(key, in: uploads[key]?.conversation ?? job.conversation)
            guard log.entries.contains(where: { $0.intent.key == key }), !stopped else { throw CancellationError() }
            uploads[key]?.reachedOwner = true
            let swept = Self.swept
            do {
                _ = try await submit(HomeIntent(key: key, op: op, issuedAt: entry.intent.issuedAt),
                                     passing: uploadedAgain ? nil : swept)
                return
            } catch let rejection as HomeRejection where rejection == swept && !uploadedAgain {
                // Uploads again and resends under a new key in the same
                // place in the log and the conversation's queue.
                uploadedAgain = true
                let next = IdempotencyKey.make()
                restartUploads(from: key, as: next)
                uploads[next]?.uploadedAfterSweep = true
                replaceInSendQueue(key, with: next)
                afterLogChange(op)
                key = next
            }
        }
    }

    func enqueueSend(_ key: IdempotencyKey, in conversation: ConversationID) {
        guard sendQueue[conversation]?.contains(key) != true else { return }
        sendQueue[conversation, default: []].append(key)
    }

    /// Returns once `key` is first in its conversation's queue, or left it.
    /// While it waits the entry is marked queued (never resent).
    func waitForTurn(_ key: IdempotencyKey, in conversation: ConversationID) async {
        guard !stopped, let keys = sendQueue[conversation], keys.contains(key), keys.first != key else { return }
        log.setQueued(key, true)
        await withCheckedContinuation { turnWaiters[key] = $0 }
        log.setQueued(key, false)
    }

    /// The owner decided `key` (or it will never be sent): the next send in
    /// its conversation may go.
    func leaveSendQueue(_ key: IdempotencyKey) {
        for (conversation, keys) in sendQueue where keys.contains(key) {
            removeFromSendQueue(conversation) { $0 == key }
        }
    }

    private func replaceInSendQueue(_ key: IdempotencyKey, with next: IdempotencyKey) {
        for (conversation, keys) in sendQueue {
            guard let index = keys.firstIndex(of: key) else { continue }
            sendQueue[conversation]?[index] = next
        }
    }

    func removeFromSendQueue(_ conversation: ConversationID, where gone: (IdempotencyKey) -> Bool) {
        guard var keys = sendQueue[conversation] else { return }
        keys.removeAll(where: gone)
        sendQueue[conversation] = keys.isEmpty ? nil : keys
        if let first = keys.first, let waiter = turnWaiters.removeValue(forKey: first) { waiter.resume() }
    }

    /// Uploads again every send whose upload a disconnect interrupted, in
    /// log order.
    func resumeInterruptedUploads() {
        for entry in log.entries {
            let key = entry.intent.key
            guard uploads[key]?.waitingForReconnect == true else { continue }
            uploads[key]?.resumedImmediately = false
            resumeUpload(key)
        }
    }

    func resumeUpload(_ key: IdempotencyKey) {
        uploads[key]?.waitingForReconnect = false
        Task { try? await self.uploadAndSubmit(key, background: true) }
    }

    /// The owner swept an upload before the send that names it arrived.
    static let swept = HomeRejection.invalid("unknown_attachment")

    /// A resend or a same-key retry got `unknown_attachment`: moves the send
    /// to a new key in the same place in the log and its conversation's
    /// queue, ready to upload everything again, once per send (and once per
    /// retry). Nil when it already did, or the send has no attachments.
    func uploadAgainAfterSweep(_ key: IdempotencyKey) -> IdempotencyKey? {
        guard let job = uploads[key], job.reachedOwner, !job.uploadedAfterSweep else { return nil }
        cancelBackoff(key)
        let next = IdempotencyKey.make()
        restartUploads(from: key, as: next)
        uploads[next]?.uploadedAfterSweep = true
        if sendQueue[job.conversation]?.contains(key) == true {
            replaceInSendQueue(key, with: next)
        } else {
            enqueueSend(next, in: job.conversation)
        }
        return next
    }

    /// Moves a refused send's upload job to `newKey` with nothing uploaded,
    /// and rekeys its log entry in place.
    func restartUploads(from key: IdempotencyKey, as newKey: IdempotencyKey) {
        guard var job = uploads.removeValue(forKey: key) else { return }
        job.uploaded = []
        job.stored = [:]
        job.reachedOwner = false
        uploads[newKey] = job
        log.rekey(key, to: newKey)
    }

    /// The op with each attachment part's mime type, byte count and poster
    /// taken from the owner's stored ref for its hash.
    static func adopting(_ stored: [String: AttachmentRef], in op: HomeOp) -> HomeOp {
        guard case .sendMessage(let conversation, let parts) = op else { return op }
        let adopted = parts.map { part -> MessagePart in
            guard case .attachment(var ref) = part, let record = stored[ref.hash] else { return part }
            ref.mimeType = record.mimeType
            ref.byteCount = record.byteCount
            ref.poster = record.poster
            ref.preview = record.preview
            return .attachment(ref)
        }
        return .sendMessage(conversation: conversation, parts: adopted)
    }

    /// Uploads, at most `uploadConcurrency` at once, every attachment of the
    /// job not uploaded yet. Successes count even when another one fails.
    /// A cached file the OS purged fails the pass with
    /// `attachment_file_missing` before anything uploads: the bytes are
    /// gone, so the user attaches the file again.
    private func uploadMissing(of key: IdempotencyKey, attempt: Int) async -> HomeRejection? {
        guard let job = uploads[key] else { return nil }
        let pending = job.attachments.filter { !job.uploaded.contains($0.ref.hash) }
        let fm = FileManager.default
        for attachment in pending {
            let posterGone = attachment.ref.poster != nil && attachment.posterURL.map { !fm.fileExists(atPath: $0.path) } ?? true
            let previewGone = attachment.ref.preview != nil && attachment.previewURL.map { !fm.fileExists(atPath: $0.path) } ?? true
            if !fm.fileExists(atPath: attachment.fileURL.path) || posterGone || previewGone {
                return .invalid("attachment_file_missing")
            }
        }
        let source = self.source
        let conversation = job.conversation
        var failure: HomeRejection?
        await withTaskGroup(of: (String, Result<AttachmentRef, Error>).self) { group in
            var next = pending.makeIterator()
            func add(_ attachment: LocalAttachment) {
                let hash = attachment.ref.hash
                let upload = AttachmentUpload(conversation: conversation, fileURL: attachment.fileURL, ref: attachment.ref,
                                              posterURL: attachment.posterURL,
                                              previewURL: attachment.previewURL) { [weak self] fraction in
                    Task { @MainActor [weak self] in self?.uploadProgressed(key, attempt: attempt, hash: hash, fraction) }
                }
                group.addTask {
                    do { return (hash, .success(try await source.upload(upload))) } catch { return (hash, .failure(error)) }
                }
            }
            for _ in 0..<Self.uploadConcurrency { if let attachment = next.next() { add(attachment) } }
            for await (hash, result) in group {
                guard uploads[key]?.attempt == attempt else { continue } // cancelled
                switch result {
                case .success(let stored) where stored.hash == hash:
                    uploads[key]?.uploaded.insert(hash)
                    uploads[key]?.stored[hash] = stored
                    if uploads[key]?.active == true { uploads[key]?.progress[hash] = 1 }
                    bumpUploadRow(key)
                case .success:
                    failure = failure ?? .invalid("attachment_hash_mismatch")
                case .failure(let error):
                    failure = failure ?? Self.rejection(for: error)
                }
                if let attachment = next.next() { add(attachment) }
            }
        }
        return failure
    }

    /// Ignores callbacks of an ended pass (a late callback after a failure,
    /// or from an earlier attempt during a retry).
    private func uploadProgressed(_ key: IdempotencyKey, attempt: Int, hash: String, _ fraction: Double) {
        guard let job = uploads[key], job.active, job.attempt == attempt, !job.uploaded.contains(hash) else { return }
        let value = min(max(fraction, 0), 1)
        let current = job.progress[hash] ?? 0
        // Forward only, and skip changes a progress ring cannot show.
        guard value > current, value - current >= 0.01 || value == 1 else { return }
        uploads[key]?.progress[hash] = value
        bumpUploadRow(key)
    }

    private func bumpUploadRow(_ key: IdempotencyKey) {
        if let conversation = uploads[key]?.conversation { bumpTranscript(conversation) }
    }

    static func rejection(for error: Error) -> HomeRejection {
        if let rejection = error as? HomeRejection { return rejection }
        if error is URLError { return .ownerUnreachable }
        if error is CancellationError { return .indeterminate }
        return .invalid("attachment_upload_failed")
    }
}
