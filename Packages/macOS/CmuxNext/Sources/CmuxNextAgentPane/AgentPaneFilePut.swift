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

    /// `_acpmux/file_put {sessionId, fileName, data}` on this Mac's acpmux, which saves the file on the
    /// machine that runs session `sessionId` (a peer's chat goes to that peer) and answers its path
    /// there. Throws ``AgentPaneFilePutFailure``.
    @concurrent static func putFile(socketPath: String, sessionId: String, name: String, data: Data,
                                    deadline: Duration = .seconds(120)) async throws -> String {
        try await putFile(sessionId: sessionId, name: name, data: data) { params in
            try await call(socketPath: socketPath, method: filePutMethod, params: params, deadline: deadline,
                           detailed: true, requiredFeature: filePutFeature)
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
}
