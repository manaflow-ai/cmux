public import CmuxAgentChat
internal import CMUXMobileCore
public import Foundation

/// Terminal-scoped artifact RPCs, extracted from `MobileChatEventSource.swift`,
/// which sits at its file-length budget.
extension MobileChatEventSource {
    private func recordTerminalTrace(
        operation: DiagnosticTerminalTraceOperation,
        phase: DiagnosticTerminalTracePhase,
        traceID: DiagnosticTerminalTraceID,
        surfaceID: String,
        startedAt: Date? = nil,
        detail: Int? = nil
    ) {
        let elapsed = startedAt.map {
            UInt32(clamping: Int(max(0, Date().timeIntervalSince($0)) * 1_000))
        }
        diagnosticLog?.recordTerminalTrace(
            operation: operation,
            phase: phase,
            traceID: traceID,
            surface: DiagnosticCorrelation().handle(for: surfaceID),
            elapsedMilliseconds: elapsed,
            detail: detail
        )
    }

    /// Scans file references rendered by one terminal surface.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the terminal.
    ///   - surfaceID: Terminal surface to scan.
    ///   - visibleOnly: Whether to scan only the rendered viewport. The default
    ///     keeps the existing visible-screen-plus-scrollback behavior.
    ///   - countOnly: Whether to skip terminal items and return only the bound
    ///     session's complete gallery count when supported.
    ///   - includeMissing: Whether missing Session rows count toward the result.
    /// - Returns: Capped file references detected by the Mac.
    public func terminalArtifactScan(
        workspaceID: String,
        surfaceID: String,
        visibleOnly: Bool = false,
        countOnly: Bool = false,
        includeMissing: Bool = true
    ) async throws -> TerminalArtifactScanResponse {
        let startedAt = Date()
        let traceID = DiagnosticTerminalTraceID()
        recordTerminalTrace(operation: .artifactScan, phase: .started, traceID: traceID, surfaceID: surfaceID)
        var params: [String: Any] = [
            "workspace_id": workspaceID,
            "surface_id": surfaceID,
            "include_missing": includeMissing,
            "trace_id": traceID.stringValue,
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
        recordTerminalTrace(
            operation: .artifactScan,
            phase: .requestSent,
            traceID: traceID,
            surfaceID: surfaceID,
            startedAt: startedAt
        )
        do {
            let response: TerminalArtifactScanResponse = try await artifactCall(
                method: "mobile.terminal.artifact.scan",
                params: params
            )
            recordAppEvent(
                .terminalArtifactListLoaded,
                correlationID: surfaceID,
                startedAt: startedAt,
                count: response.artifacts.count
            )
            recordTerminalTrace(
                operation: .artifactScan,
                phase: .applied,
                traceID: traceID,
                surfaceID: surfaceID,
                startedAt: startedAt,
                detail: response.artifacts.count
            )
            return response
        } catch {
            recordAppEvent(
                .terminalArtifactLoadFailed,
                correlationID: surfaceID,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
            recordTerminalTrace(
                operation: .artifactScan,
                phase: .failed,
                traceID: traceID,
                surfaceID: surfaceID,
                startedAt: startedAt
            )
            throw error
        }
    }

    /// Reads metadata for a file referenced by one terminal surface.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the terminal.
    ///   - surfaceID: Terminal surface authorizing the file reference.
    ///   - path: Absolute Mac host path.
    public func terminalArtifactStat(
        workspaceID: String,
        surfaceID: String,
        path: String
    ) async throws -> ChatArtifactStat {
        let params: [String: Any] = [
            "workspace_id": workspaceID,
            "surface_id": surfaceID,
            "path": path,
        ]
        return try await artifactCall(
            method: "mobile.terminal.artifact.stat",
            params: params
        )
    }

    public func terminalArtifactFetch(
        workspaceID: String,
        surfaceID: String,
        path: String,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
    ) async throws -> Data {
        try await performArtifactDownload(correlationID: surfaceID) {
            try await fetchArtifactChunks(
                method: "mobile.terminal.artifact.fetch",
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
    }

    /// Streams terminal-scoped artifact chunks without accumulating a second copy.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the terminal surface.
    ///   - surfaceID: Terminal surface whose visible paths authorize the fetch.
    ///   - path: Absolute Mac host path.
    ///   - onChunk: Structured callback for each fetched chunk.
    public func terminalArtifactFetch(
        workspaceID: String,
        surfaceID: String,
        path: String,
        onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws {
        _ = try await performArtifactDownload(correlationID: surfaceID) {
            try await fetchArtifactChunks(
                method: "mobile.terminal.artifact.fetch",
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
        let startedAt = Date()
        let traceID = DiagnosticTerminalTraceID()
        recordTerminalTrace(operation: .artifactList, phase: .started, traceID: traceID, surfaceID: surfaceID)
        recordAppEvent(.artifactListLoadStarted, correlationID: surfaceID)
        guard supportsTerminalArtifactList else {
            recordAppEvent(
                .artifactListLoadFailed,
                correlationID: surfaceID,
                startedAt: startedAt,
                failure: .policyUnavailable
            )
            recordTerminalTrace(
                operation: .artifactList,
                phase: .failed,
                traceID: traceID,
                surfaceID: surfaceID,
                startedAt: startedAt
            )
            throw ChatArtifactError.unsupported
        }
        do {
            let listing: ChatArtifactDirectoryListing = try await artifactCall(
                method: "mobile.terminal.artifact.list",
                params: [
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                    "path": path,
                    "trace_id": traceID.stringValue,
                ]
            )
            recordAppEvent(
                .artifactListLoadSucceeded,
                correlationID: surfaceID,
                startedAt: startedAt,
                count: listing.entries.count
            )
            recordTerminalTrace(
                operation: .artifactList,
                phase: .applied,
                traceID: traceID,
                surfaceID: surfaceID,
                startedAt: startedAt,
                detail: listing.entries.count
            )
            return listing
        } catch {
            recordAppEvent(
                .artifactListLoadFailed,
                correlationID: surfaceID,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
            recordTerminalTrace(
                operation: .artifactList,
                phase: .failed,
                traceID: traceID,
                surfaceID: surfaceID,
                startedAt: startedAt
            )
            throw error
        }
    }
}
