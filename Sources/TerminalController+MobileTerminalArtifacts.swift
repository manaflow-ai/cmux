import CmuxAgentChat
import CmuxTerminal
import Foundation

extension TerminalController {
    func mobileChatInputError(_ keyResult: TerminalSurface.NamedKeySendResult) -> V2CallResult {
        switch keyResult {
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: nil)
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: nil)
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: nil)
        case .unknownKey:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: nil)
        case .sent, .queued:
            return .ok(["accepted": true])
        }
    }

    func mobileNonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func v2MobileTerminalArtifactDispatch(
        method: String,
        params: [String: Any],
        executionContext: MobileHostRPCExecutionContext? = nil
    ) async -> V2CallResult {
        switch method {
        case "mobile.terminal.artifact.scan":
            return await v2MobileTerminalArtifactScan(params: params)
        case "mobile.terminal.artifact.stat":
            return await v2MobileTerminalArtifactStat(params: params)
        case "mobile.terminal.artifact.fetch":
            return await v2MobileTerminalArtifactFetch(
                params: params,
                executionContext: executionContext
            )
        case "mobile.terminal.artifact.thumbnail":
            return await v2MobileTerminalArtifactThumbnail(params: params)
        case "mobile.terminal.artifact.list":
            return await v2MobileTerminalArtifactList(params: params)
        default:
            return .err(code: "method_not_found", message: "Unknown mobile terminal artifact method", data: nil)
        }
    }

    func v2MobileTerminalArtifactScan(params: [String: Any]) async -> V2CallResult {
        let visibleOnly = v2Bool(params, "visible_only") ?? false
        let countOnly = v2Bool(params, "count_only") ?? false
        let includeDirectories = v2Bool(params, "include_directories") ?? false
        let resolution = await mobileTerminalArtifactContext(
            params: params,
            requiresPath: false,
            includeScrollback: !visibleOnly,
            includeTerminalText: !countOnly
        )
        guard case .success(let context) = resolution else {
            return resolution.failureResult
        }
        if countOnly {
            guard let sessionID = context.sessionID else {
                return TerminalArtifactWire.result(
                    TerminalArtifactScanResponse(artifacts: [])
                )
            }
            do {
                guard let indexedSession = try await mobileChatArtifactIndexedSession(sessionID: sessionID) else {
                    return TerminalArtifactWire.result(
                        TerminalArtifactScanResponse(artifacts: [], sessionID: sessionID)
                    )
                }
                let response = TerminalArtifactScanResponse.sessionCount(
                    sessionID: indexedSession.sessionID,
                    sessionArtifacts: indexedSession.snapshot.artifacts
                )
                return TerminalArtifactWire.result(response)
            } catch {
                return TerminalArtifactWire.result(
                    TerminalArtifactScanResponse(artifacts: [], sessionID: sessionID)
                )
            }
        }
        let response = await Task.detached(priority: .utility) {
            context.scan(includeDirectories: includeDirectories)
        }.value
        await terminalArtifactAuthorizationStore.record(
            workspaceID: context.workspaceID,
            surfaceID: context.surfaceID,
            canonicalPaths: Set(response.artifacts.map(\.path))
        )
        return TerminalArtifactWire.result(response)
    }

    func v2MobileTerminalArtifactStat(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileTerminalArtifactContext(params: params, requiresPath: true)
        guard case .success(let context) = resolution else {
            return resolution.failureResult
        }
        do {
            let stat = try await Task.detached(priority: .utility) {
                try context.authorizedRead { reader, canonicalPath in
                    try reader.stat(path: canonicalPath)
                }
            }.value
            return TerminalArtifactWire.result(stat)
        } catch TerminalArtifactReadContext.Error.forbidden {
            debugLogMobileTerminalArtifactDenial(op: "stat", path: context.requestedPath)
            return mobileTerminalArtifactError(.forbidden, path: context.requestedPath)
        } catch ArtifactByteReader.Error.fileNotFound {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        } catch ArtifactByteReader.Error.unsupportedMedia {
            return mobileTerminalArtifactError(.unsupportedMedia, path: context.requestedPath)
        } catch {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        }
    }

    func v2MobileTerminalArtifactFetch(
        params: [String: Any],
        executionContext: MobileHostRPCExecutionContext? = nil
    ) async -> V2CallResult {
        let resolution = await mobileTerminalArtifactContext(params: params, requiresPath: true)
        guard case .success(let context) = resolution else {
            return resolution.failureResult
        }
        let offset = max(0, Int64(v2Int(params, "offset") ?? 0))
        let length = ChatArtifactTransferPolicy.defaultPolicy
            .clampedChunkLength(v2Int(params, "length"))
        do {
            if v2RawString(params, "transport") == "iroh_artifact_v1" {
                guard let executionContext else {
                    return .err(
                        code: "unsupported_transport",
                        message: String(
                            localized: "mobile.chat.artifact.error.irohTransportUnavailable",
                            defaultValue: "Artifact transfer requires an authenticated session."
                        ),
                        data: nil
                    )
                }
                let canonicalPath = try await Task.detached(priority: .utility) {
                    try context.authorizedRead { _, canonicalPath in canonicalPath }
                }.value
                return TerminalArtifactWire.result(
                    try await executionContext.issueArtifactTransfer(
                        canonicalPath: canonicalPath
                    )
                )
            }
            let chunk = try await Task.detached(priority: .utility) {
                try context.authorizedRead { reader, canonicalPath in
                    try reader.fetch(path: canonicalPath, offset: offset, length: length)
                }
            }.value
            return TerminalArtifactWire.result(chunk)
        } catch let error as MobileHostIrohArtifactTransferRegistry.Error {
            switch error.issueFailure {
            case .fileNotFound:
                return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
            case .unavailable:
                return mobileTerminalArtifactError(.unavailable, path: context.requestedPath)
            }
        } catch TerminalArtifactReadContext.Error.forbidden {
            debugLogMobileTerminalArtifactDenial(op: "fetch", path: context.requestedPath)
            return mobileTerminalArtifactError(.forbidden, path: context.requestedPath)
        } catch ArtifactByteReader.Error.fileNotFound {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        } catch {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        }
    }

    func v2MobileTerminalArtifactThumbnail(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileTerminalArtifactContext(params: params, requiresPath: true)
        guard case .success(let context) = resolution else {
            return resolution.failureResult
        }
        let maxDimension = min(max(v2Int(params, "max_dimension") ?? 512, 64), 1024)
        do {
            let thumbnail = try await Task.detached(priority: .utility) {
                try context.authorizedRead { reader, canonicalPath in
                    try reader.thumbnail(path: canonicalPath, maxDimension: maxDimension)
                }
            }.value
            return TerminalArtifactWire.result(thumbnail)
        } catch TerminalArtifactReadContext.Error.forbidden {
            debugLogMobileTerminalArtifactDenial(op: "thumbnail", path: context.requestedPath)
            return mobileTerminalArtifactError(.forbidden, path: context.requestedPath)
        } catch ArtifactByteReader.Error.fileNotFound {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        } catch {
            return mobileTerminalArtifactError(.unsupportedMedia, path: context.requestedPath)
        }
    }

    func v2MobileTerminalArtifactList(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileTerminalArtifactContext(params: params, requiresPath: true)
        guard case .success(let context) = resolution else {
            return resolution.failureResult
        }
        do {
            let listing = try await Task.detached(priority: .utility) {
                try context.authorizedDirectoryList { reader, canonicalPath in
                    try reader.list(path: canonicalPath)
                }
            }.value
            return TerminalArtifactWire.result(listing)
        } catch TerminalArtifactReadContext.Error.forbidden {
            debugLogMobileTerminalArtifactDenial(op: "list", path: context.requestedPath)
            return mobileTerminalArtifactError(.forbidden, path: context.requestedPath)
        } catch ArtifactByteReader.Error.fileNotFound {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        } catch {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        }
    }

    private func mobileTerminalArtifactContext(
        params: [String: Any],
        requiresPath: Bool,
        includeScrollback: Bool = true,
        includeTerminalText: Bool = true
    ) async -> TerminalArtifactContextResolution {
        guard let workspaceID = v2RawString(params, "workspace_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let surfaceID = v2RawString(params, "surface_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceID.isEmpty,
              !surfaceID.isEmpty,
              !requiresPath || v2RawString(params, "path")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .failure(.err(
                code: "invalid_params",
                message: String(
                    localized: "mobile.terminal.artifact.error.invalidParams",
                    defaultValue: "workspace_id, surface_id, and path are required."
                ),
                data: nil
            ))
        }
        let scanAuthorizedPaths = requiresPath
            ? await terminalArtifactAuthorizationStore.authorizedPaths(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
            : []
        let directoryAccessMode = mobileArtifactDirectoryAccessMode()
        return v2MainSync { () -> TerminalArtifactContextResolution in
            guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
                  let resolvedSurfaceID = resolved.surfaceId,
                  let terminalPanel = resolved.workspace.terminalPanel(for: resolvedSurfaceID) else {
                return .failure(mobileTerminalArtifactError(.notFound, path: v2RawString(params, "path")))
            }
            let workingDirectory = resolved.workspace.effectivePanelDirectory(
                panelId: resolvedSurfaceID,
                localFallback: mobileNonEmpty(terminalPanel.directory) ?? mobileNonEmpty(terminalPanel.requestedWorkingDirectory)
            ) ?? resolved.workspace.currentDirectory
            let terminalText = includeTerminalText
                ? readTerminalTextForSnapshot(
                    terminalPanel: terminalPanel,
                    includeScrollback: includeScrollback,
                    lineLimit: nil,
                    allowVTExport: includeScrollback
                ) ?? ""
                : ""
            let sessionID = agentChatTranscriptService.flatMap {
                $0.currentOrMostRecentSessionRecord(surfaceID: resolvedSurfaceID.uuidString)?.sessionID
            }
            return .success(TerminalArtifactReadContext(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                terminalText: terminalText,
                workingDirectory: workingDirectory,
                requestedPath: v2RawString(params, "path"),
                sessionID: sessionID,
                scanAuthorizedPaths: scanAuthorizedPaths,
                directoryAccessMode: directoryAccessMode
            ))
        }
    }

    private enum MobileTerminalArtifactErrorKind {
        case notFound
        case forbidden
        case fileNotFound
        case unsupportedMedia
        case unavailable
    }

    private func debugLogMobileTerminalArtifactDenial(op: String, path: String?) {
        #if DEBUG
        cmuxDebugLog("mobile.terminal.artifact.forbidden op=\(op) path=\(path ?? "nil")")
        #endif
    }

    private func mobileTerminalArtifactError(
        _ kind: MobileTerminalArtifactErrorKind,
        path: String?
    ) -> V2CallResult {
        switch kind {
        case .notFound:
            return .err(
                code: "not_found",
                message: String(
                    localized: "mobile.terminal.artifact.error.terminalNotFound",
                    defaultValue: "That terminal is no longer available."
                ),
                data: nil
            )
        case .forbidden:
            return .err(
                code: "forbidden",
                message: String(
                    localized: "mobile.terminal.artifact.error.forbidden",
                    defaultValue: "That file is not currently shown in this terminal."
                ),
                data: path.map { ["path": $0] }
            )
        case .fileNotFound:
            return .err(
                code: "file_not_found",
                message: String(
                    localized: "mobile.chat.artifact.error.fileNotFound",
                    defaultValue: "That file is no longer available on the Mac."
                ),
                data: path.map { ["path": $0] }
            )
        case .unsupportedMedia:
            return .err(
                code: "unsupported_media",
                message: String(
                    localized: "mobile.chat.artifact.error.unsupportedMedia",
                    defaultValue: "This file type cannot be previewed."
                ),
                data: path.map { ["path": $0] }
            )
        case .unavailable:
            return .err(
                code: "unavailable",
                message: String(
                    localized: "mobile.chat.artifact.error.transferUnavailable",
                    defaultValue: "Artifact transfer is temporarily unavailable."
                ),
                data: nil
            )
        }
    }
}

private enum TerminalArtifactContextResolution {
    case success(TerminalArtifactReadContext)
    case failure(TerminalController.V2CallResult)

    var failureResult: TerminalController.V2CallResult {
        switch self {
        case .success:
            return .err(code: "internal_error", message: "unexpected success", data: nil)
        case .failure(let result):
            return result
        }
    }
}

private struct TerminalArtifactReadContext: Sendable {
    enum Error: Swift.Error {
        case forbidden
    }

    let workspaceID: String
    let surfaceID: String
    private let terminalText: String
    private let workingDirectory: String?
    let requestedPath: String?
    let sessionID: String?
    private let scanAuthorizedPaths: Set<String>
    private let directoryAccessMode: ChatArtifactScope.DirectoryAccessMode

    init(
        workspaceID: String,
        surfaceID: String,
        terminalText: String,
        workingDirectory: String?,
        requestedPath: String?,
        sessionID: String?,
        scanAuthorizedPaths: Set<String>,
        directoryAccessMode: ChatArtifactScope.DirectoryAccessMode
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.terminalText = terminalText
        self.workingDirectory = workingDirectory
        self.requestedPath = requestedPath
        self.sessionID = sessionID
        self.scanAuthorizedPaths = scanAuthorizedPaths
        self.directoryAccessMode = directoryAccessMode
    }

    func scan(includeDirectories: Bool) -> TerminalArtifactScanResponse {
        let reader = ArtifactByteReader()
        let scope = TerminalArtifactScope(
            terminalText: terminalText,
            workingDirectory: workingDirectory,
            resolver: ChatArtifactScope.FoundationResolver(),
            directoryAccessMode: directoryAccessMode
        )
        let artifacts = scope.artifactPaths(limit: 200).compactMap { path -> TerminalArtifactReference? in
            guard let stat = try? reader.stat(path: path) else { return nil }
            guard includeDirectories || !stat.isDirectory else { return nil }
            return TerminalArtifactReference(
                path: path,
                kind: stat.kind,
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                size: stat.size,
                modifiedAt: stat.modifiedAt
            )
        }
        return TerminalArtifactScanResponse(artifacts: artifacts, sessionID: sessionID)
    }

    func authorizedRead<T>(
        _ operation: (ArtifactByteReader, String) throws -> T
    ) throws -> T {
        guard let requestedPath else { throw Error.forbidden }
        let resolver = ChatArtifactScope.FoundationResolver()
        let snapshotScope = ChatArtifactScope(
            referencedPaths: scanAuthorizedPaths,
            directoryAccessMode: directoryAccessMode,
            resolver: resolver
        )
        if let canonicalPath = snapshotScope.canonicalFilePath(for: requestedPath) {
            return try operation(ArtifactByteReader(), canonicalPath)
        }
        let scope = TerminalArtifactScope(
            terminalText: terminalText,
            workingDirectory: workingDirectory,
            resolver: resolver,
            directoryAccessMode: directoryAccessMode
        )
        guard let canonicalPath = scope.canonicalPath(for: requestedPath) else {
            throw Error.forbidden
        }
        return try operation(ArtifactByteReader(), canonicalPath)
    }

    func authorizedDirectoryList<T>(
        _ operation: (ArtifactByteReader, String) throws -> T
    ) throws -> T {
        guard let requestedPath else { throw Error.forbidden }
        let resolver = ChatArtifactScope.FoundationResolver()
        let snapshotScope = ChatArtifactScope(
            referencedPaths: scanAuthorizedPaths,
            directoryAccessMode: directoryAccessMode,
            resolver: resolver
        )
        if let canonicalPath = snapshotScope.canonicalDirectoryListPath(for: requestedPath) {
            return try operation(ArtifactByteReader(), canonicalPath)
        }
        let scope = TerminalArtifactScope(
            terminalText: terminalText,
            workingDirectory: workingDirectory,
            resolver: resolver,
            directoryAccessMode: directoryAccessMode
        )
        guard let canonicalPath = scope.canonicalDirectoryListPath(for: requestedPath) else {
            throw Error.forbidden
        }
        return try operation(ArtifactByteReader(), canonicalPath)
    }
}

private struct TerminalArtifactWire {
    static func result<T: Encodable>(_ value: T) -> TerminalController.V2CallResult {
        let coding = ChatWireCoding()
        guard let data = try? coding.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .err(
                code: "internal_error",
                message: "Failed to encode terminal artifact response",
                data: nil
            )
        }
        return .ok(object)
    }
}
