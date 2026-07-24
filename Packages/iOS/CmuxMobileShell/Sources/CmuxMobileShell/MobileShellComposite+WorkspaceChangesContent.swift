public import CmuxAgentChat
public import CmuxMobileChanges
internal import CmuxMobileDiagnostics
public import Foundation
internal import CmuxMobileRPC

extension MobileShellComposite {
    /// Decodes a content chunk (up to 3 MiB of base64 per fetch) off the main
    /// actor so binary previews and expansion downloads never run their JSON
    /// pass on the UI thread.
    nonisolated static func decodeContentResponse<T: Decodable & Sendable>(
        _ response: Data
    ) async throws -> WorkspaceChangesContentResponse<T> {
        try ChatWireCoding().decode(
            WorkspaceChangesContentResponse<T>.self,
            from: response
        )
    }

    /// Maximum current-file size accepted by the unchanged-line expander.
    private static let workspaceChangesExpansionByteLimit: Int64 = 5 * 1_024 * 1_024
    /// Maximum decoded lines accepted by the unchanged-line expander.
    nonisolated static let workspaceChangesExpansionLineLimit = 200_000

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
        try await workspaceChangesFileStatResponse(
            workspaceID: workspaceID,
            path: path,
            revision: revision
        ).value
    }

    private func workspaceChangesFileStatResponse(
        workspaceID: String,
        path: String,
        revision: WorkspaceChangesFileRevision
    ) async throws -> WorkspaceChangesContentResponse<ChatArtifactStat> {
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
        try await workspaceChangesFileFetchResponse(
            workspaceID: workspaceID,
            path: path,
            revision: revision,
            offset: offset,
            length: length
        ).value
    }

    private func workspaceChangesFileFetchResponse(
        workspaceID: String,
        path: String,
        revision: WorkspaceChangesFileRevision,
        offset: Int64,
        length: Int
    ) async throws -> WorkspaceChangesContentResponse<ChatArtifactChunk> {
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
        let statResponse = try await workspaceChangesFileStatResponse(
            workspaceID: workspaceID,
            path: path,
            revision: revision
        )
        return try await workspaceChangesContentChunks(
            workspaceID: workspaceID,
            path: path,
            revision: revision,
            expectedFingerprint: statResponse.contentFingerprint,
            collectsData: true,
            progress: progress,
            onChunk: { _ in }
        )
    }

    /// Creates a path-scoped loader for current working-tree text lines.
    ///
    /// The returned value performs an authorized stat before using the existing
    /// chunked content fetcher and refuses files larger than 5 MiB.
    ///
    /// - Parameter workspaceID: Mac-local workspace identifier.
    /// - Returns: A closure that fetches and splits one current file.
    public func workspaceChangesCurrentFileLinesLoader(
        workspaceID: String
    ) -> @MainActor @Sendable (String) async throws -> DiffExpansionCurrentFile {
        { path in
            let statResponse = try await self.workspaceChangesFileStatResponse(
                workspaceID: workspaceID,
                path: path,
                revision: .current
            )
            guard statResponse.value.size <= Self.workspaceChangesExpansionByteLimit else {
                throw DiffExpansionContentError.tooLarge
            }
            let content = try await self.workspaceChangesCurrentFileContent(
                workspaceID: workspaceID,
                path: path,
                expectedFingerprint: statResponse.contentFingerprint
            )
            guard content.data.count <= Self.workspaceChangesExpansionByteLimit else {
                throw DiffExpansionContentError.tooLarge
            }
            let lines = try await Self.workspaceChangesLines(from: content.data)
            return DiffExpansionCurrentFile(
                lines: lines,
                contentFingerprints:
                    [statResponse.contentFingerprint] + content.fingerprints
            )
        }
    }

    private func workspaceChangesCurrentFileContent(
        workspaceID: String,
        path: String,
        expectedFingerprint: String?
    ) async throws -> (data: Data, fingerprints: [String?]) {
        let chunkLength = ChatArtifactTransferPolicy.defaultPolicy.maxRawChunkBytes
        let downloadPolicy = WorkspaceChangesExpansionDownloadPolicy(
            byteLimit: Self.workspaceChangesExpansionByteLimit,
            chunkLength: chunkLength
        )
        var offset: Int64 = 0
        var result = Data()
        var fingerprints: [String?] = []
        var receivedChunkCount = 0
        while true {
            try Task.checkCancellation()
            let response = try await workspaceChangesFileFetchResponse(
                workspaceID: workspaceID,
                path: path,
                revision: .current,
                offset: offset,
                length: chunkLength
            )
            let chunk = response.value
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: expectedFingerprint,
                observed: response.contentFingerprint
            )
            receivedChunkCount += 1
            try downloadPolicy.validate(
                totalSize: chunk.totalSize,
                accumulatedByteCount: result.count,
                nextChunkByteCount: chunk.data.count,
                receivedChunkCount: receivedChunkCount
            )
            fingerprints.append(response.contentFingerprint)
            if result.isEmpty, chunk.totalSize > 0, chunk.totalSize <= Int64(Int.max) {
                result.reserveCapacity(Int(chunk.totalSize))
            }
            result.append(chunk.data)
            offset = chunk.offset + Int64(chunk.data.count)
            if chunk.eof { return (result, fingerprints) }
            guard !chunk.data.isEmpty else {
                throw ChatArtifactError.macUnreachable
            }
        }
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
        let statResponse = try await workspaceChangesFileStatResponse(
            workspaceID: workspaceID,
            path: path,
            revision: revision
        )
        _ = try await workspaceChangesContentChunks(
            workspaceID: workspaceID,
            path: path,
            revision: revision,
            expectedFingerprint: statResponse.contentFingerprint,
            collectsData: false,
            progress: nil,
            onChunk: onChunk
        )
    }

    private func workspaceChangesContentCall<T: Decodable & Sendable>(
        _ request: WorkspaceChangesContentRequest
    ) async throws -> WorkspaceChangesContentResponse<T> {
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
            return try await Self.decodeContentResponse(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            MobileDebugLog.anchormux(
                "changes.content error method=\(request.method) params=\(request.params) error=\(error)"
            )
            throw Self.workspaceChangesArtifactError(from: error)
        }
    }

    private func workspaceChangesContentChunks(
        workspaceID: String,
        path: String,
        revision: WorkspaceChangesFileRevision,
        expectedFingerprint: String?,
        collectsData: Bool,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?,
        onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws -> Data {
        try await MobileArtifactChunkFetchLoop().run(
            collectsData: collectsData,
            progress: progress
        ) { offset in
            let response = try await self.workspaceChangesFileFetchResponse(
                workspaceID: workspaceID,
                path: path,
                revision: revision,
                offset: offset,
                length: ChatArtifactTransferPolicy.defaultPolicy.maxRawChunkBytes
            )
            try WorkspaceChangesContentFingerprintPolicy().validate(
                expected: expectedFingerprint,
                observed: response.contentFingerprint
            )
            return response.value
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

    nonisolated static func workspaceChangesLines(from data: Data) async throws -> [String] {
        guard !data.isEmpty else { return [] }

        var lines: [String] = []
        var lineStart = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            guard lines.count < workspaceChangesExpansionLineLimit else {
                throw DiffExpansionContentError.tooLarge
            }
            lines.append(String(decoding: data[lineStart..<index], as: UTF8.self))
            lineStart = data.index(after: index)
        }
        if lineStart < data.endIndex {
            guard lines.count < workspaceChangesExpansionLineLimit else {
                throw DiffExpansionContentError.tooLarge
            }
            lines.append(String(decoding: data[lineStart..<data.endIndex], as: UTF8.self))
        }
        return lines
    }
}
