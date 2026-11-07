import Foundation

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
    /// The upload plan, its chunks and the read cursor are the SDK's rules.
    private var rules: ConversationRules { ConversationRules() }

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
            let plan: ConversationRules.UploadPlan
            do {
                plan = try rules.uploadPlan(attachment: attachment, needs: begun.needs,
                                            hasPosterFile: posterFile != nil, hasPreviewFile: previewFile != nil)
            } catch ConversationRules.Failure.refused(_, let code) {
                throw DaemonError.malformedResponse("attachment begin: \(code.replacingOccurrences(of: "_", with: " "))")
            }
            for piece in plan.pieces {
                let url: URL? = switch piece.variant {
                case .original: file
                case .poster: posterFile
                case .preview: previewFile
                }
                guard let url else { throw DaemonError.malformedResponse("attachment begin: \(piece.variant.rawValue) needed") }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                // Up to the declared size; a file shorter than declared ends at its EOF
                // and the commit refuses it (`incomplete`).
                for index in 0..<piece.chunkCount {
                    try Task.checkCancellation()
                    let chunk = try rules.uploadChunk(piece, total: plan.total, index: index)
                    guard let offset = Int(exactly: chunk.offset), let length = Int(exactly: chunk.length) else {
                        throw DaemonError.malformedResponse("attachment upload: chunk does not fit in Int")
                    }
                    let bytes = try handle.read(upToCount: length) ?? Data()
                    guard !bytes.isEmpty else { break }
                    _ = try await connection.request(Upload(step: .chunk(upload: upload, piece: piece.variant, offset: offset, bytes: bytes)),
                                                     timeout: chunkTimeout)
                    progress(chunk.progress)
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
    /// Returns the variant's mime type.
    func download(conversation: String, hash: String, variant: ConversationAttachmentVariant, to destination: URL) async throws -> String {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        var moved = false
        defer { if !moved { try? FileManager.default.removeItem(at: temporary) } }
        let handle = try FileHandle(forWritingTo: temporary)
        var mimeType = "application/octet-stream"
        do {
            defer { try? handle.close() }
            let length = try rules.attachmentChunkBytes()
            var next: UInt64? = 0
            // Ends at the owner's eof; a read that moves no bytes before it is an error (`read_next`).
            while let offset = next {
                try Task.checkCancellation()
                guard let start = Int(exactly: offset) else { throw DaemonError.malformedResponse("attachment read: offset does not fit in Int") }
                let reply = try await connection.request(
                    Read(read: ConversationAttachmentReadRequest(conversation: conversation, hash: hash, variant: variant, offset: start,
                                                                 length: length)),
                    timeout: readTimeout)
                guard let bytes = Data(base64Encoded: reply.data) else { throw DaemonError.malformedResponse("attachment read: data is not base64") }
                try handle.write(contentsOf: bytes)
                mimeType = reply.mimeType
                do {
                    next = try rules.readNext(offset: offset, received: bytes.count, eof: reply.eof)
                } catch ConversationRules.Failure.refused(_, let code) {
                    throw DaemonError.malformedResponse("attachment read: \(code.replacingOccurrences(of: "_", with: " "))")
                }
            }
            try handle.synchronize()
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
            moved = true
        } catch where FileManager.default.fileExists(atPath: destination.path) {
            // A concurrent read of the same variant placed identical bytes first.
        }
        return mimeType
    }
}
