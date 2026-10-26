public import Foundation

/// Why a file the person dropped into a chat whose agent runs on an ssh peer (acpmux peering, a
/// chat named `huge-blue/<name>`) did not reach that machine (``AgentPaneHostProviding/putFile(sessionId:name:data:)``).
public nonisolated enum AgentPaneFilePutFailure: Error, Equatable, Sendable {
    /// This Mac's acpmux or the peer's takes no files (a build from before `_acpmux/file_put`), or
    /// the host has no acpmux: the chat takes no uploads and the composer keeps its own note.
    case unsupported
    /// Past an older acpmux's size cap (`filePut.tooLarge`); a current one takes any size.
    case tooLarge
    /// The disk of the machine that runs the chat lacks room for the file (`filePut.noSpace`),
    /// with its free bytes.
    case noSpace(freeBytes: Int64)
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
                : refusal.name == "filePut.tooLarge" ? .tooLarge
                : refusal.name == "filePut.noSpace" ? .noSpace(freeBytes: refusal.freeBytes ?? 0) : .failed
        } else {
            self = .failed
        }
    }
}

/// One step of a file streamed to the machine that runs a chat as the page sends it
/// (``AgentPaneHostProviding/putFile(sessionId:step:)``, acpmux `_acpmux/file_put_begin`,
/// `_chunk`, `_finish`, `_cancel`): nothing of it is staged on this Mac, and a chunk's base64 text
/// goes on as the page sent it.
public nonisolated enum AgentPaneFilePutStep: Sendable, Equatable {
    case begin(name: String, size: Int)
    case chunk(upload: String, offset: Int, base64: String)
    case finish(upload: String, name: String, size: Int)
    case cancel(upload: String)
}

/// What one ``AgentPaneFilePutStep`` did on the machine that runs the chat.
public nonisolated enum AgentPaneFilePutProgress: Sendable, Equatable {
    case begun(upload: String)
    case wrote(offset: Int)
    case saved(path: String)
    case cancelled
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

    /// One step of a streamed upload on this Mac's acpmux, which takes it to the daemon that runs
    /// session `sessionId` (a peer's chat: that peer). Throws ``AgentPaneFilePutFailure``.
    @concurrent static func putFile(socketPath: String, sessionId: String, step: AgentPaneFilePutStep,
                                    deadline: Duration = .seconds(120)) async throws -> AgentPaneFilePutProgress {
        try await putFile(sessionId: sessionId, step: step) { method, params in
            try await call(socketPath: socketPath, method: method, params: params, deadline: deadline,
                           detailed: true, requiredFeature: filePutChunksFeature)
        }
    }

    /// ``putFile(socketPath:sessionId:step:deadline:)`` with `send`, which runs the request.
    static func putFile(sessionId: String, step: AgentPaneFilePutStep,
                        send: @Sendable (_ method: String, _ params: [String: any Sendable]) async throws -> [String: Any]) async throws -> AgentPaneFilePutProgress {
        do {
            switch step {
            case .begin(let name, let size):
                let answer = try await send(filePutBeginMethod, ["sessionId": sessionId, "fileName": name, "size": size])
                guard let upload = answer["uploadId"] as? String, !upload.isEmpty else { throw AgentPaneFilePutFailure.failed }
                return .begun(upload: upload)
            case .chunk(let upload, let offset, let base64):
                let answer = try await send(filePutChunkMethod, ["sessionId": sessionId, "uploadId": upload, "offset": offset, "data": base64])
                guard let next = (answer["offset"] as? NSNumber)?.intValue, next > offset else { throw AgentPaneFilePutFailure.failed }
                return .wrote(offset: next)
            case .finish(let upload, let name, let size):
                let answer = try await send(filePutFinishMethod, ["sessionId": sessionId, "uploadId": upload, "fileName": name, "size": size])
                guard let path = answer["path"] as? String, !path.isEmpty else { throw AgentPaneFilePutFailure.failed }
                return .saved(path: path)
            case .cancel(let upload):
                _ = try await send(filePutCancelMethod, ["sessionId": sessionId, "uploadId": upload])
                return .cancelled
            }
        } catch let failure as AgentPaneFilePutFailure {
            throw failure
        } catch {
            throw AgentPaneFilePutFailure(error)
        }
    }

    /// ``putFile(socketPath:sessionId:name:data:deadline:)`` with `send`, which runs the request.
    static func putFile(sessionId: String, name: String, data: Data,
                        send: @Sendable (_ params: [String: any Sendable]) async throws -> [String: Any]) async throws -> String {
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
    /// exchange, so a peer WebSocket never receives the entire base64 file in one frame. A failure
    /// part way cancels it, which deletes the partial file there.
    static func putFileChunked(sessionId: String, name: String, data: Data,
                               send: @Sendable (_ method: String, _ params: [String: any Sendable]) async throws -> [String: Any]) async throws -> String {
        let begun = try await putFile(sessionId: sessionId, step: .begin(name: name, size: data.count), send: send)
        guard case .begun(let upload) = begun else { throw AgentPaneFilePutFailure.failed }
        do {
            var offset = 0
            while offset < data.count {
                let end = min(offset + filePutChunkBytes, data.count)
                let chunk = AgentPaneFilePutStep.chunk(upload: upload, offset: offset, base64: data[offset..<end].base64EncodedString())
                guard try await putFile(sessionId: sessionId, step: chunk, send: send) == .wrote(offset: end) else { throw AgentPaneFilePutFailure.failed }
                offset = end
            }
            let finished = try await putFile(sessionId: sessionId, step: .finish(upload: upload, name: name, size: data.count), send: send)
            guard case .saved(let path) = finished else { throw AgentPaneFilePutFailure.failed }
            return path
        } catch {
            _ = try? await putFile(sessionId: sessionId, step: .cancel(upload: upload), send: send)
            throw error
        }
    }
}
