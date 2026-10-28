import CmuxNextWakeups
import Foundation
import CmuxNextCompat

/// Attachment bytes over one daemon connection: a chunked upload by SHA-256
/// and a chunked read into a local file. The local owner
/// (`conversation-attachment-*`) and the Cloud proxy (`cloud-attachment-*`)
/// take the same steps; `Upload` and `Read` name the commands, the
/// timeouts how long each step may take (a Cloud `commit` sends the bytes on).
struct AttachmentTransfer<Upload: AttachmentUploadStep, Read: AttachmentReadStep> {
    let connection: DaemonConnection
    /// `begin`'s deadline; nil: the connection's default.
    var beginTimeout: Duration?
    var chunkTimeout: Duration
    var commitTimeout: Duration
    var readTimeout: Duration

    /// Uploads `attachment`'s bytes from `file` (and its poster or preview
    /// from `posterFile` / `previewFile`) to `conversation`. A hash the
    /// conversation already holds returns the kept record without sending
    /// bytes. `progress` gets the fraction sent, 0...1. A failure after
    /// `begin` cancels the upload on the daemon (best effort).
    func upload(conversation: String, attachment: ConversationAttachment, file: URL, posterFile: URL?, previewFile: URL?,
                progress: (Double) -> Void) async throws -> StoredConversationAttachment {
        let beginStep = Upload(step: .begin(conversation: conversation, attachment: attachment))
        let begun = if let beginTimeout {
            try await connection.request(beginStep, timeout: beginTimeout)
        } else {
            try await connection.request(beginStep)
        }
        guard let upload = begun.upload else {
            guard let stored = begun.stored else { throw DaemonError.malformedResponse("attachment begin: no upload and no record") }
            progress(1)
            return stored
        }
        do {
            let needs = begun.needs ?? [.original]
            var pieces: [(variant: ConversationAttachmentVariant, url: URL, size: Int)] = []
            for variant in needs {
                switch variant {
                case .original: pieces.append((variant, file, attachment.byteCount))
                case .poster:
                    guard let posterFile, let poster = attachment.poster else { throw DaemonError.malformedResponse("attachment begin: poster needed") }
                    pieces.append((variant, posterFile, poster.byteCount))
                case .preview:
                    guard let previewFile, let preview = attachment.preview else { throw DaemonError.malformedResponse("attachment begin: preview needed") }
                    pieces.append((variant, previewFile, preview.byteCount))
                }
            }
            let total = max(1, pieces.reduce(0) { $0 + $1.size })
            var sent = 0
            for piece in pieces {
                let handle = try FileHandle.blockingForReading(from: piece.url)
                defer { try? handle.close() }
                var offset = 0
                // Ends at the declared size; a file shorter than declared ends at its EOF
                // and the commit refuses it (`incomplete`).
                while offset < piece.size {
                    try Task.checkCancellation()
                    let bytes = try handle.blockingRead(upToCount: min(ConversationClient.attachmentChunkBytes, piece.size - offset)) ?? Data()
                    guard !bytes.isEmpty else { break }
                    _ = try await connection.request(Upload(step: .chunk(upload: upload, piece: piece.variant, offset: offset, bytes: bytes)),
                                                     timeout: chunkTimeout)
                    offset += bytes.count
                    sent += bytes.count
                    progress(min(0.99, Double(sent) / Double(total)))
                }
            }
            let committed = try await connection.request(Upload(step: .commit(upload: upload)), timeout: commitTimeout)
            guard let stored = committed.stored else { throw DaemonError.malformedResponse("attachment commit: no record") }
            progress(1)
            return stored
        } catch {
            _ = try? await connection.request(Upload(step: .cancel(upload: upload)))
            throw error
        }
    }

    /// Reads `variant` of `hash` in `conversation` into `destination`
    /// atomically: the bytes land in a temporary file beside it that moves
    /// into place only when complete, so a cancelled read leaves nothing.
    /// Every disk step runs on `work`'s files lane, never on the caller's
    /// thread (a Home page awaits this from the main actor).
    /// Returns the variant's mime type.
    func download(conversation: String, hash: String, variant: ConversationAttachmentVariant, to destination: URL,
                  on work: BackgroundWork) async throws -> String {
        let partial = try await work.run(.userVisible, mayBlock: .files) { try AttachmentPartialFile.create(for: destination) }
        var offset = 0
        var mimeType = "application/octet-stream"
        do {
            var eof = false
            // Ends at the owner's eof; a read that moves no bytes before it is an error.
            while !eof {
                try Task.checkCancellation()
                let reply = try await connection.request(
                    Read(read: ConversationAttachmentReadRequest(conversation: conversation, hash: hash, variant: variant, offset: offset,
                                                                 length: ConversationClient.attachmentChunkBytes)),
                    timeout: readTimeout)
                guard let bytes = Data(base64Encoded: reply.data) else { throw DaemonError.malformedResponse("attachment read: data is not base64") }
                let at = offset
                try await work.run(.userVisible, mayBlock: .files) { try partial.write(bytes, at: at) }
                offset += bytes.count
                mimeType = reply.mimeType
                eof = reply.eof
                guard eof || !bytes.isEmpty else { throw DaemonError.malformedResponse("attachment read: no progress before eof") }
            }
        } catch {
            // Posted, not awaited: a cancelled caller's run would be refused before it starts. Block-shutdown, so a
            // quit that has begun still takes this one close and unlink (cache eviction skips hidden files).
            work.post(.userVisible, mayBlock: .files, shutdown: .blockShutdown) { partial.discard() }
            throw error
        }
        do {
            try await work.run(.userVisible, mayBlock: .files) { try partial.finish() }
        } catch is CancellationError {
            work.post(.userVisible, mayBlock: .files, shutdown: .blockShutdown) { partial.discard() }
            throw CancellationError()
        }
        return mimeType
    }
}
