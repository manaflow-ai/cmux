public import CmuxAgentChat
public import Foundation
internal import CmuxMobileRPC

extension MobileShellComposite {
    /// Reads artifact-compatible metadata for a changed file revision.
    ///
    /// - Parameters:
    ///   - workspaceID: Mac-local workspace identifier.
    ///   - path: Current changed path, or a rename's old path for ``WorkspaceChangesFileRevision/base``.
    ///   - revision: Working-tree or comparison-base revision.
    /// - Returns: Metadata consumed by the shared artifact viewer.
    /// - Throws: ``ChatArtifactError`` when the Mac rejects or cannot serve the path.
    public func workspaceChangesFileStat(
        workspaceID: String,
        path: String,
        revision: WorkspaceChangesFileRevision
    ) async throws -> ChatArtifactStat {
        let request = WorkspaceChangesContentRequest.stat(
            workspaceID: workspaceID,
            path: path,
            revision: revision
        )
        return try await workspaceChangesContentCall(request)
    }

    /// Reads one artifact-compatible chunk for a changed file revision.
    ///
    /// - Parameters:
    ///   - workspaceID: Mac-local workspace identifier.
    ///   - path: Current changed path, or a rename's old path for ``WorkspaceChangesFileRevision/base``.
    ///   - revision: Working-tree or comparison-base revision.
    ///   - offset: Byte offset requested from the Mac.
    ///   - length: Requested chunk length; the Mac clamps it to 3 MiB.
    /// - Returns: Decoded chunk bytes and transfer metadata.
    /// - Throws: ``ChatArtifactError`` when the Mac rejects or cannot serve the path.
    public func workspaceChangesFileFetch(
        workspaceID: String,
        path: String,
        revision: WorkspaceChangesFileRevision,
        offset: Int64,
        length: Int
    ) async throws -> ChatArtifactChunk {
        let request = WorkspaceChangesContentRequest.fetch(
            workspaceID: workspaceID,
            path: path,
            revision: revision,
            offset: offset,
            length: length
        )
        return try await workspaceChangesContentCall(request)
    }

    /// Fetches a complete changed file while reporting cumulative progress.
    ///
    /// - Parameters:
    ///   - workspaceID: Mac-local workspace identifier.
    ///   - path: Revision-appropriate changed path.
    ///   - revision: Working-tree or comparison-base revision.
    ///   - progress: Optional cumulative byte progress callback.
    /// - Returns: The complete file bytes.
    /// - Throws: ``ChatArtifactError`` for transport, authorization, or file failures.
    public func workspaceChangesFileData(
        workspaceID: String,
        path: String,
        revision: WorkspaceChangesFileRevision,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> Data {
        try await workspaceChangesContentChunks(
            workspaceID: workspaceID,
            path: path,
            revision: revision,
            collectsData: true,
            progress: progress,
            onChunk: { _ in }
        )
    }

    /// Streams changed-file chunks in order without accumulating a second copy.
    ///
    /// - Parameters:
    ///   - workspaceID: Mac-local workspace identifier.
    ///   - path: Revision-appropriate changed path.
    ///   - revision: Working-tree or comparison-base revision.
    ///   - onChunk: Structured callback awaited before fetching the next chunk.
    /// - Throws: ``ChatArtifactError`` for transport, authorization, or file failures.
    public func streamWorkspaceChangesFile(
        workspaceID: String,
        path: String,
        revision: WorkspaceChangesFileRevision,
        onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws {
        _ = try await workspaceChangesContentChunks(
            workspaceID: workspaceID,
            path: path,
            revision: revision,
            collectsData: false,
            progress: nil,
            onChunk: onChunk
        )
    }

    private func workspaceChangesContentCall<T: Decodable>(
        _ request: WorkspaceChangesContentRequest
    ) async throws -> T {
        do {
            let client = try workspaceChangesClient()
            let requestData = try MobileCoreRPCClient.requestData(
                method: request.method,
                params: request.params
            )
            let response = try await client.sendRequest(requestData)
            guard remoteClient === client, connectionState == .connected else {
                throw CancellationError()
            }
            return try ChatWireCoding().decode(T.self, from: response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.workspaceChangesArtifactError(from: error)
        }
    }

    private func workspaceChangesContentChunks(
        workspaceID: String,
        path: String,
        revision: WorkspaceChangesFileRevision,
        collectsData: Bool,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?,
        onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws -> Data {
        try await MobileArtifactChunkFetchLoop().run(
            collectsData: collectsData,
            progress: progress
        ) { offset in
            try await self.workspaceChangesFileFetch(
                workspaceID: workspaceID,
                path: path,
                revision: revision,
                offset: offset,
                length: ChatArtifactTransferPolicy.defaultPolicy.maxRawChunkBytes
            )
        } onChunk: { chunk in
            try await onChunk(chunk)
        }
    }

    private nonisolated static func workspaceChangesArtifactError(
        from error: any Error
    ) -> ChatArtifactError {
        guard let connectionError = error as? MobileShellConnectionError else {
            return .macUnreachable
        }
        guard case .rpcError(let code, _) = connectionError else {
            return .macUnreachable
        }
        switch code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "invalid_params":
            return .invalidParams
        case "forbidden":
            return .forbidden
        case "file_not_found", "not_found":
            return .fileNotFound
        case "unsupported_media":
            return .unsupportedMedia
        default:
            return .macUnreachable
        }
    }
}
