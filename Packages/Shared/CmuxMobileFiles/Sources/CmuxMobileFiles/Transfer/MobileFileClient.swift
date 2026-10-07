import CmuxLink
import CmuxMobileLink
import CmuxMobileWire
import Foundation

/// Resumable, sha256-verified transfers and directory reads against one Mac
/// (c4-files.md section 4). Cancelling the calling task closes the channel
/// at once; the Mac keeps an upload partial for a later resume.
public struct MobileFileClient: Sendable {
    /// Payload bytes per upload chunk, kept under `hello.ok.max_frame`.
    public static let defaultChunkBytes = 128 * 1024

    /// The one phone session with this Mac (shared with terminals and the rest).
    public let session: MobileLinkClient
    public var chunkBytes: Int
    /// Send budget of a bulk channel (link credit).
    public var budgetBytes: Int

    public init(session: MobileLinkClient, chunkBytes: Int = MobileFileClient.defaultChunkBytes,
                budgetBytes: Int = 4 * 1024 * 1024) {
        self.session = session
        self.chunkBytes = chunkBytes
        self.budgetBytes = budgetBytes
    }

    // MARK: Upload

    /// Uploads `file` and returns the Mac's `files.upload.done`. `progress`
    /// gets (bytes the Mac holds or the link accepted, total), starting with
    /// the resume offset.
    public func upload(_ file: URL, name: String, mime: String, sha256: String, dest: FilesUploadDestination,
                       progress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws -> FilesUploadDone {
        let source = try FileReader(url: file)
        let size = source.size
        let params = FilesUploadParams(name: name, size: size, mime: mime, sha256: sha256, dest: dest)
        let maxFrame = try await mapped { try await session.helloOK().maxFrame }
        let chunk = max(1024, min(chunkBytes, maxFrame - 64))
        let (channel, opened) = try await open(.filesUpload, params: try Self.object(params), stream: "files.upload/\(name)")
        let resume = try JSONValue.object(opened.params).decode(as: FilesUploadOpenedParams.self)
        guard resume.offset <= size else {
            await channel.abort()
            throw MobileClientError(code: "proto.bad_record", message: "resume offset past the end")
        }
        return try await withTaskCancellationHandler {
            var offset = resume.offset
            progress(offset, size)
            while offset < size {
                try Task.checkCancellation()
                let data = try source.read(at: offset, count: Int(min(UInt64(chunk), size - offset)))
                do {
                    try await channel.send(binary: FileChunk(offset: offset, data: data).encoded)
                } catch {
                    throw await Self.closure(of: channel) ?? MobileClientError.disconnected
                }
                offset += UInt64(data.count)
                progress(offset, size)
            }
            try await channel.send(message: FilesUploadEnd(sha256: sha256).message)
            switch await channel.receive() {
            case .json(let value):
                if case .message(let message)? = try? MobileJSON(value: value), let done = FilesUploadDone(message) {
                    await channel.finish()
                    return done
                }
                await channel.abort()
                throw Self.error(in: value) ?? MobileClientError(code: "proto.bad_record", message: "unexpected answer")
            case .binary, .gap, .closed:
                await channel.abort()
                throw MobileClientError.disconnected
            }
        } onCancel: {
            Task { await channel.abort() }
        }
    }

    // MARK: Download

    /// Downloads `path` into `part` (resuming from its length), verifies
    /// sha256 and returns the opened info. When `expectedSHA256` is set and
    /// the Mac's file changed, the part is discarded and the download restarts.
    public func download(_ path: String, into part: URL, expectedSHA256: String? = nil,
                         opened: @Sendable (FilesDownloadOpenedParams) async -> Void = { _ in },
                         progress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws -> FilesDownloadOpenedParams {
        let writer = try FileWriter(url: part)
        var offset = writer.length
        var (channel, info) = try await openDownload(path, offset: offset)
        let changed = expectedSHA256.map { $0 != info.sha256 } ?? false
        if offset > 0, changed || offset > info.size {
            await channel.abort()
            try writer.truncate()
            offset = 0
            (channel, info) = try await openDownload(path, offset: 0)
        }
        await opened(info)
        let size = info.size
        let live = channel
        return try await withTaskCancellationHandler {
            progress(offset, size)
            receive: while true {
                try Task.checkCancellation()
                switch await live.receive() {
                case .binary(let payload, let flags):
                    let chunk = try FileChunk(decoding: payload)
                    guard chunk.offset == offset, offset + UInt64(chunk.data.count) <= size else {
                        await live.abort()
                        throw MobileClientError(code: "proto.bad_record", message: "chunk at \(chunk.offset), expected \(offset)")
                    }
                    try writer.write(chunk.data, at: offset)
                    offset += UInt64(chunk.data.count)
                    progress(offset, size)
                    if flags.contains(.fin) { break receive }
                case .json(let value):
                    await live.abort()
                    throw Self.error(in: value) ?? MobileClientError(code: "proto.bad_record", message: "unexpected record")
                case .gap:
                    await live.abort()
                    throw MobileClientError(code: "proto.bad_record", message: "bytes were lost; resume")
                case .closed:
                    throw MobileClientError.disconnected
                }
            }
            await live.finish()
            guard offset == size, try writer.sha256() == info.sha256 else {
                try? FileManager.default.removeItem(at: part)
                throw MobileClientError(code: "files.digest_mismatch", message: "the downloaded bytes do not match sha256")
            }
            return info
        } onCancel: {
            Task { await live.abort() }
        }
    }

    private func openDownload(_ path: String, offset: UInt64) async throws -> (MobileChannel, FilesDownloadOpenedParams) {
        let params = FilesDownloadParams(path: path, offset: offset > 0 ? offset : nil)
        let (channel, opened) = try await open(.filesDownload, params: try Self.object(params), stream: "files.download")
        return (channel, try JSONValue.object(opened.params).decode(as: FilesDownloadOpenedParams.self))
    }

    // MARK: Reads

    public func list(_ path: String, after: String? = nil, limit: Int? = nil) async throws -> FilesListResult {
        let params = try JSONValue(encoding: FilesListParams(path: path, after: after, limit: limit))
        return try await mapped { try await session.read("files.list", params: params) }.decode(as: FilesListResult.self)
    }

    public func roots() async throws -> [FilesRoot] {
        try await mapped { try await session.read("files.roots", params: .object([:])) }.decode(as: FilesRootsResult.self).roots
    }

    /// A bulk channel on the shared session.
    private func open(_ kind: ChannelKind, params: [String: JSONValue], stream: String)
        async throws -> (MobileChannel, ChannelOpenedFrame) {
        let request = MobileChannelRequest(kind: kind, channelClass: .bulk, window: 4 * 1024 * 1024, params: params,
                                           stream: stream, priority: .bulk, budgetBytes: budgetBytes)
        let opened = try await mapped { try await session.open(request) }
        return (opened.channel, opened.opened)
    }

    /// Runs `body`, reporting session failures as `MobileClientError`.
    private func mapped<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw MobileClientError.from(error)
        }
    }

    // MARK: Helpers

    static func object<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        try JSONValue(encoding: value).objectValue ?? [:]
    }

    /// The Mac's last word on a channel whose send failed.
    static func closure(of channel: MobileChannel) async -> MobileClientError? {
        if case .json(let value) = await channel.receive() { return error(in: value) }
        return nil
    }

    static func error(in value: JSONValue) -> MobileClientError? {
        switch try? MobileFrame(value: value) {
        case .channelClosed(let closed)?: MobileClientError(closed: closed)
        case .error(let error)?: MobileClientError(code: error.code, message: error.message, retryable: error.retryable)
        default: nil
        }
    }
}
