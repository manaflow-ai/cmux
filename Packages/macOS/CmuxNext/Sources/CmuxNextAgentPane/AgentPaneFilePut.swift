public import Foundation

/// Why a file the person dropped into a chat whose agent runs on an ssh peer (acpmux peering, a
/// chat named `huge-blue/<name>`) did not reach that machine (``AgentPaneHostProviding/putFile(sessionId:name:data:)``).
public nonisolated enum AgentPaneFilePutFailure: Error, Equatable, Sendable {
    /// This Mac's acpmux or the peer's takes no files (a build from before `_acpmux/file_put`), or
    /// the host has no acpmux: the chat takes no uploads and the composer keeps its own note.
    case unsupported
    /// Past ``AgentPaneUpload/maximumPeerFileBytes``.
    case tooLarge
    /// No answer, a refusal, or a write that failed on the peer.
    case failed

    /// The failure an acpmux call threw: an older daemon, or a peer it refused for that
    /// (`filePut.unsupported`, JSON-RPC "Method not found"), is ``unsupported``.
    public init(_ error: any Error) {
        if let failure = error as? Self {
            self = failure
        } else if let failure = error as? AcpmuxStatusClient.Failure, case .unsupportedFeature = failure {
            self = .unsupported
        } else if let refusal = error as? AcpmuxRPCError {
            self = refusal.isMethodMissing || refusal.name == "filePut.unsupported" ? .unsupported
                : refusal.name == "filePut.tooLarge" ? .tooLarge : .failed
        } else {
            self = .failed
        }
    }
}

extension AcpmuxStatusClient {
    /// The `initialize` feature of an acpmux that takes `_acpmux/file_put` (acpmux
    /// `hub/file_uploads.rs`); one without it is never sent the bytes.
    static let filePutFeature = "filePut"
    static let filePutMethod = "_acpmux/file_put"
    static let filePutChunksFeature = "filePutChunks"
    static let filePutBeginMethod = "_acpmux/file_put_begin"
    static let filePutChunkMethod = "_acpmux/file_put_chunk"
    static let filePutFinishMethod = "_acpmux/file_put_finish"
    static let filePutCancelMethod = "_acpmux/file_put_cancel"
    nonisolated static let legacyFilePutBytes = 10 * 1024 * 1024
    static let filePutChunkBytes = 512 * 1024

    /// `_acpmux/file_put {sessionId, fileName, data}` on this Mac's acpmux, which saves the file on the
    /// machine that runs session `sessionId` (a peer's chat goes to that peer) and answers its path
    /// there. Throws ``AgentPaneFilePutFailure``.
    @concurrent static func putFile(socketPath: String, sessionId: String, name: String, data: Data,
                                    deadline: Duration = .seconds(120)) async throws -> String {
        guard data.count <= AgentPaneUpload.maximumPeerFileBytes else { throw AgentPaneFilePutFailure.tooLarge }
        if data.count <= legacyFilePutBytes {
            return try await putFile(sessionId: sessionId, name: name, data: data) { params in
                try await call(socketPath: socketPath, method: filePutMethod, params: params, deadline: deadline,
                               detailed: true, requiredFeature: filePutFeature)
            }
        }
        return try await putFileChunked(sessionId: sessionId, name: name, data: data) { method, params in
            try await call(socketPath: socketPath, method: method, params: params, deadline: deadline,
                           detailed: true, requiredFeature: filePutChunksFeature)
        }
    }

    /// Streams a staged peer file without loading its whole contents into memory.
    @concurrent static func putFile(socketPath: String, sessionId: String, name: String, file: URL,
                                    deadline: Duration = .seconds(120)) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= AgentPaneUpload.maximumPeerFileBytes else { throw AgentPaneFilePutFailure.tooLarge }
        if size <= legacyFilePutBytes {
            return try await putFile(socketPath: socketPath, sessionId: sessionId, name: name,
                                     data: try Data(contentsOf: file), deadline: deadline)
        }
        return try await putFileChunked(sessionId: sessionId, name: name, size: size, file: file) { method, params in
            try await call(socketPath: socketPath, method: method, params: params, deadline: deadline,
                           detailed: true, requiredFeature: filePutChunksFeature)
        }
    }

    /// ``putFile(socketPath:sessionId:name:data:deadline:)`` with `send`, which runs the request.
    static func putFile(sessionId: String, name: String, data: Data,
                        send: @Sendable (_ params: [String: any Sendable]) async throws -> [String: Any]) async throws -> String {
        guard data.count <= AgentPaneUpload.maximumPeerFileBytes else { throw AgentPaneFilePutFailure.tooLarge }
        let result: [String: Any]
        do {
            result = try await send(["sessionId": sessionId, "fileName": name, "data": data.base64EncodedString()])
        } catch {
            throw AgentPaneFilePutFailure(error)
        }
        guard let path = result["path"] as? String, !path.isEmpty else { throw AgentPaneFilePutFailure.failed }
        return path
    }

    /// Streams a larger upload over begin/chunk/finish requests. Each request is a fresh bounded
    /// exchange, so a peer WebSocket never receives the entire base64 file in one frame.
    static func putFileChunked(sessionId: String, name: String, data: Data,
                               send: @Sendable (_ method: String, _ params: [String: any Sendable]) async throws -> [String: Any]) async throws -> String {
        guard data.count <= AgentPaneUpload.maximumPeerFileBytes else { throw AgentPaneFilePutFailure.tooLarge }
        var upload: String?
        let started: [String: Any]
        do {
            started = try await send(filePutBeginMethod, ["sessionId": sessionId, "fileName": name, "size": data.count])
            guard let id = started["uploadId"] as? String, !id.isEmpty else { throw AgentPaneFilePutFailure.failed }
            upload = id
            var offset = 0
            while offset < data.count {
                let end = min(offset + filePutChunkBytes, data.count)
                let piece = data[offset..<end]
                let answer = try await send(filePutChunkMethod, ["sessionId": sessionId, "uploadId": upload,
                                                                  "offset": offset, "data": Data(piece).base64EncodedString()])
                guard let next = answer["offset"] as? NSNumber, next.intValue == end else { throw AgentPaneFilePutFailure.failed }
                offset = end
            }
            let finished = try await send(filePutFinishMethod, ["sessionId": sessionId, "uploadId": upload,
                                                                 "fileName": name, "size": data.count])
            guard let path = finished["path"] as? String, !path.isEmpty else { throw AgentPaneFilePutFailure.failed }
            return path
        } catch {
            if let upload {
                try? await send(filePutCancelMethod, ["sessionId": sessionId, "uploadId": upload])
            }
            if let failure = error as? AgentPaneFilePutFailure { throw failure }
            throw AgentPaneFilePutFailure(error)
        }
    }

    private static func putFileChunked(sessionId: String, name: String, size: Int, file: URL,
                                       send: @Sendable (_ method: String, _ params: [String: any Sendable]) async throws -> [String: Any]) async throws -> String {
        var upload: String?
        do {
            let started = try await send(filePutBeginMethod, ["sessionId": sessionId, "fileName": name, "size": size])
            guard let id = started["uploadId"] as? String, !id.isEmpty else { throw AgentPaneFilePutFailure.failed }
            upload = id
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var offset = 0
            while offset < size {
                let piece = try handle.read(upToCount: min(filePutChunkBytes, size - offset)) ?? Data()
                guard !piece.isEmpty else { throw AgentPaneFilePutFailure.failed }
                let end = offset + piece.count
                let answer = try await send(filePutChunkMethod, ["sessionId": sessionId, "uploadId": id,
                                                                  "offset": offset, "data": piece.base64EncodedString()])
                guard let next = answer["offset"] as? NSNumber, next.intValue == end else { throw AgentPaneFilePutFailure.failed }
                offset = end
            }
            let finished = try await send(filePutFinishMethod, ["sessionId": sessionId, "uploadId": id,
                                                                 "fileName": name, "size": size])
            guard let path = finished["path"] as? String, !path.isEmpty else { throw AgentPaneFilePutFailure.failed }
            return path
        } catch {
            if let upload { try? await send(filePutCancelMethod, ["sessionId": sessionId, "uploadId": upload]) }
            if let failure = error as? AgentPaneFilePutFailure { throw failure }
            throw AgentPaneFilePutFailure(error)
        }
    }
}
