public import CmuxAgentChat
public import Foundation

/// Terminal-scoped artifact RPCs, extracted from `MobileChatEventSource.swift`,
/// which sits at its file-length budget.
extension MobileChatEventSource {
    /// Scans file references rendered by one terminal surface.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the terminal.
    ///   - surfaceID: Terminal surface to scan.
    ///   - visibleOnly: Whether to scan only the rendered viewport. The default
    ///     keeps the existing visible-screen-plus-scrollback behavior.
    ///   - countOnly: Whether to skip terminal items and return only the bound
    ///     session's complete gallery count when supported.
    /// - Returns: Capped file references detected by the Mac.
    public func terminalArtifactScan(
        workspaceID: String,
        surfaceID: String,
        visibleOnly: Bool = false,
        countOnly: Bool = false
    ) async throws -> TerminalArtifactScanResponse {
        var params: [String: Any] = [
            "workspace_id": workspaceID,
            "surface_id": surfaceID,
        ]
        if visibleOnly {
            params["visible_only"] = true
        }
        if countOnly {
            params["count_only"] = true
        }
        if supportsTerminalArtifactList {
            params["include_directories"] = true
        }
        return try await artifactCall(
            method: "mobile.terminal.artifact.scan",
            params: params
        )
    }

    public func terminalArtifactStat(
        workspaceID: String,
        surfaceID: String,
        path: String
    ) async throws -> ChatArtifactStat {
        try await artifactCall(
            method: "mobile.terminal.artifact.stat",
            params: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "path": path,
            ]
        )
    }

    public func terminalArtifactFetch(
        workspaceID: String,
        surfaceID: String,
        path: String,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
    ) async throws -> Data {
        var offset: Int64 = 0
        var result = Data()
        while true {
            let chunk: ChatArtifactChunk = try await artifactCall(
                method: "mobile.terminal.artifact.fetch",
                params: [
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                    "path": path,
                    "offset": offset,
                    "length": ChatArtifactTransferPolicy.defaultPolicy.maxRawChunkBytes,
                ]
            )
            if result.isEmpty, chunk.totalSize > 0, chunk.totalSize <= Int64(Int.max) {
                result.reserveCapacity(Int(chunk.totalSize))
            }
            result.append(chunk.data)
            offset = chunk.offset + Int64(chunk.data.count)
            progress?(offset, chunk.totalSize)
            if chunk.eof {
                return result
            }
            guard !chunk.data.isEmpty else {
                throw ChatArtifactError.macUnreachable
            }
        }
    }

    public func terminalArtifactThumbnail(
        workspaceID: String,
        surfaceID: String,
        path: String,
        maxDimension: Int
    ) async throws -> ChatArtifactThumbnail {
        try await artifactCall(
            method: "mobile.terminal.artifact.thumbnail",
            params: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "path": path,
                "max_dimension": maxDimension,
            ]
        )
    }

    /// Lists immediate entries in a terminal-visible artifact directory.
    public func terminalArtifactList(
        workspaceID: String,
        surfaceID: String,
        path: String
    ) async throws -> ChatArtifactDirectoryListing {
        guard supportsTerminalArtifactList else {
            throw ChatArtifactError.unsupported
        }
        return try await artifactCall(
            method: "mobile.terminal.artifact.list",
            params: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "path": path,
            ]
        )
    }
}
