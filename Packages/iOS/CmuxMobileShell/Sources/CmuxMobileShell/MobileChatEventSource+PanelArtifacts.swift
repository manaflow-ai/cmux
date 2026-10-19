public import CmuxAgentChat
public import Foundation

/// Panel-scoped artifact RPCs for the one file a Mac panel currently displays.
extension MobileChatEventSource {
    /// Reads metadata for a file-backed panel's displayed file.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the panel.
    ///   - surfaceID: Markdown or file-preview panel surface.
    ///   - path: Absolute Mac host path from the surface descriptor.
    /// - Returns: Metadata for the displayed file.
    /// - Throws: ``ChatArtifactError`` when the host is unavailable, the panel
    ///   no longer authorizes the path, or metadata cannot be read.
    public func panelArtifactStat(
        workspaceID: String,
        surfaceID: String,
        path: String
    ) async throws -> ChatArtifactStat {
        guard supportsPanelArtifacts else { throw ChatArtifactError.unsupported }
        return try await artifactCall(
            method: "mobile.panel.artifact.stat",
            params: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "path": path,
            ]
        )
    }

    /// Fetches the complete displayed panel file through bounded chunks.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the panel.
    ///   - surfaceID: Markdown or file-preview panel surface.
    ///   - path: Absolute Mac host path from the surface descriptor.
    ///   - progress: Optional callback receiving fetched and total byte counts.
    /// - Returns: The displayed file's bytes.
    /// - Throws: ``ChatArtifactError`` when the host is unavailable, the panel
    ///   no longer authorizes the path, or transfer fails.
    public func panelArtifactFetch(
        workspaceID: String,
        surfaceID: String,
        path: String,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
    ) async throws -> Data {
        guard supportsPanelArtifacts else { throw ChatArtifactError.unsupported }
        return try await fetchArtifactChunks(
            method: "mobile.panel.artifact.fetch",
            stringParams: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "path": path,
            ],
            collectsData: true,
            progress: progress,
            onChunk: { _ in }
        )
    }

    /// Streams the displayed panel file without accumulating a second copy.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the panel.
    ///   - surfaceID: Markdown or file-preview panel surface.
    ///   - path: Absolute Mac host path from the surface descriptor.
    ///   - onChunk: Async consumer invoked once for every received chunk.
    /// - Throws: ``ChatArtifactError`` when the host is unavailable, the panel
    ///   no longer authorizes the path, or transfer fails. Consumer errors are
    ///   propagated unchanged.
    public func panelArtifactFetch(
        workspaceID: String,
        surfaceID: String,
        path: String,
        onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws {
        guard supportsPanelArtifacts else { throw ChatArtifactError.unsupported }
        _ = try await fetchArtifactChunks(
            method: "mobile.panel.artifact.fetch",
            stringParams: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "path": path,
            ],
            collectsData: false,
            progress: nil,
            onChunk: onChunk
        )
    }

    /// Generates a bounded thumbnail for the displayed panel file.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the panel.
    ///   - surfaceID: Markdown or file-preview panel surface.
    ///   - path: Absolute Mac host path from the surface descriptor.
    ///   - maxDimension: Maximum thumbnail width or height in pixels.
    /// - Returns: Encoded thumbnail bytes and metadata.
    /// - Throws: ``ChatArtifactError`` when the host is unavailable, the panel
    ///   no longer authorizes the path, or thumbnail generation fails.
    public func panelArtifactThumbnail(
        workspaceID: String,
        surfaceID: String,
        path: String,
        maxDimension: Int
    ) async throws -> ChatArtifactThumbnail {
        guard supportsPanelArtifacts else { throw ChatArtifactError.unsupported }
        return try await artifactCall(
            method: "mobile.panel.artifact.thumbnail",
            params: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "path": path,
                "max_dimension": maxDimension,
            ]
        )
    }
}
