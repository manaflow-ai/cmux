public import Foundation

/// Attachment bytes over one daemon connection (`local-attachments-v1`):
/// chunked uploads by SHA-256 and chunked reads into a local file.
extension ConversationClient {
    /// Decoded bytes per chunk and per read: the daemon's limit (4 MiB, about
    /// 5.6 MiB of base64 inside a 16 MiB request line).
    public static let attachmentChunkBytes = 4 << 20
    /// A chunk's deadline: 4 MiB over a local socket takes milliseconds;
    /// this bounds a stalled daemon, not a slow disk.
    static let attachmentChunkTimeout: Duration = .seconds(30)

    public static func supportsAttachments(_ connection: DaemonConnection) async -> Bool {
        await connection.identity?.supports(DaemonCapabilities.shared.localAttachments) == true
    }

    private func requireAttachments() async throws {
        guard await Self.supportsAttachments(connection) else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.shared.localAttachments])
        }
    }

    /// Uploads `attachment`'s bytes from `file` (and its poster or preview
    /// from `posterFile` / `previewFile`) to `conversation`. A hash the
    /// conversation already holds returns the kept record without sending
    /// bytes. `progress` gets the fraction sent, 0...1. A failure after
    /// `begin` cancels the upload on the daemon (best effort).
    public func uploadAttachment(conversation: String, attachment: ConversationAttachment, file: URL,
                                 posterFile: URL? = nil, previewFile: URL? = nil,
                                 progress: @Sendable (Double) -> Void = { _ in }) async throws -> StoredConversationAttachment {
        try await requireAttachments()
        let begun = try await connection.request(ConversationAttachmentUploadRequest.begin(conversation: conversation,
                                                                                         attachment: attachment))
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
                let handle = try FileHandle(forReadingFrom: piece.url)
                defer { try? handle.close() }
                var offset = 0
                while true {
                    try Task.checkCancellation()
                    let bytes = try handle.read(upToCount: Self.attachmentChunkBytes) ?? Data()
                    if bytes.isEmpty { break }
                    _ = try await connection.request(ConversationAttachmentUploadRequest.chunk(upload: upload, piece: piece.variant,
                                                                                               offset: offset, bytes: bytes),
                                                     timeout: Self.attachmentChunkTimeout)
                    offset += bytes.count
                    sent += bytes.count
                    progress(min(0.99, Double(sent) / Double(total)))
                }
            }
            let committed = try await connection.request(ConversationAttachmentUploadRequest.commit(upload: upload),
                                                         timeout: Self.attachmentChunkTimeout)
            guard let stored = committed.stored else { throw DaemonError.malformedResponse("attachment commit: no record") }
            progress(1)
            return stored
        } catch {
            _ = try? await connection.request(ConversationAttachmentUploadRequest.cancel(upload: upload))
            throw error
        }
    }

    /// Reads `variant` of `hash` in `conversation` into `destination`
    /// atomically: the bytes land in a temporary file beside it that moves
    /// into place only when complete, so a cancelled read leaves nothing.
    /// Returns the variant's mime type.
    @discardableResult
    public func downloadAttachment(conversation: String, hash: String, variant: ConversationAttachmentVariant,
                                   to destination: URL) async throws -> String {
        try await requireAttachments()
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        var moved = false
        defer { if !moved { try? FileManager.default.removeItem(at: temporary) } }
        let handle = try FileHandle(forWritingTo: temporary)
        var offset = 0
        var mimeType = "application/octet-stream"
        do {
            defer { try? handle.close() }
            while true {
                try Task.checkCancellation()
                let reply = try await connection.request(
                    ConversationAttachmentReadRequest(conversation: conversation, hash: hash, variant: variant, offset: offset,
                                                      length: Self.attachmentChunkBytes),
                    timeout: Self.attachmentChunkTimeout)
                guard let bytes = Data(base64Encoded: reply.data) else { throw DaemonError.malformedResponse("attachment read: data is not base64") }
                try handle.write(contentsOf: bytes)
                offset += bytes.count
                mimeType = reply.mimeType
                if reply.eof { break }
                guard !bytes.isEmpty else { throw DaemonError.malformedResponse("attachment read: no progress before eof") }
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
