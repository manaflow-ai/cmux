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
        let includeMissing = v2Bool(params, "include_missing") ?? true
        let requestsGalleryRowTotal = params.keys.contains("include_missing")
        // Count-only refreshes recur on every settled output change, so they
        // must not capture terminal text up front: `readTerminalTextForSnapshot`
        // takes the Ghostty surface lock inside `v2MainSync`, and a session
        // workspace never uses the text for a count. Only the no-session
        // fallback re-resolves with viewport text below.
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
                guard visibleOnly, requestsGalleryRowTotal else {
                    return TerminalArtifactWire.result(
                        TerminalArtifactScanResponse(artifacts: [])
                    )
                }
                let textResolution = await mobileTerminalArtifactContext(
                    params: params,
                    requiresPath: false,
                    includeScrollback: false,
                    includeTerminalText: true
                )
                guard case .success(let textContext) = textResolution else {
                    return textResolution.failureResult
                }
                let scanned = await Task.detached(priority: .utility) {
                    textContext.scan(includeDirectories: includeDirectories)
                }.value
                return TerminalArtifactWire.result(
                    TerminalArtifactScanResponse(
                        artifacts: [],
                        galleryRowTotal: scanned.response.artifacts.count
                    )
                )
            }
            do {
                let indexedSession = try await mobileChatArtifactIndexedSession(sessionID: sessionID)
                let galleryRowTotal: Int?
                if requestsGalleryRowTotal {
                    galleryRowTotal = await mobileChatArtifactGalleryRowTotal(
                        sessionID: indexedSession.sessionID,
                        generation: indexedSession.snapshot.generation,
                        artifacts: indexedSession.snapshot.artifacts,
                        includeDirectories: includeDirectories,
                        includeMissing: includeMissing
                    )
                } else {
                    galleryRowTotal = nil
                }
                let response = TerminalArtifactScanResponse.sessionCount(
                    sessionID: indexedSession.sessionID,
                    sessionArtifacts: indexedSession.snapshot.artifacts,
                    galleryRowTotal: galleryRowTotal
                )
                return TerminalArtifactWire.result(response)
            } catch {
                return TerminalArtifactWire.result(
                    TerminalArtifactScanResponse(artifacts: [], sessionID: sessionID)
                )
            }
        }
        let scanned = await Task.detached(priority: .utility) {
            context.scan(includeDirectories: includeDirectories)
        }.value
        let response = scanned.response
        await terminalArtifactAuthorizationStore.record(
            workspaceID: context.workspaceID,
            surfaceID: context.surfaceID,
            canonicalPaths: Set(response.artifacts.map(\.path)),
            identities: scanned.identities
        )
        return TerminalArtifactWire.result(response)
    }

    func v2MobileTerminalArtifactStat(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileTerminalArtifactContext(params: params, requiresPath: true)
        guard case .success(let context) = resolution else {
            return resolution.failureResult
        }
        do {
            let outcome = try await Task.detached(priority: .utility) {
                do {
                    return TerminalArtifactStatOutcome.success(
                        try context.authorizedStat { reader, canonicalPath, identity in
                            try reader.stat(
                                path: canonicalPath,
                                authorizedCanonicalPath: canonicalPath,
                                authorizedIdentity: identity
                            )
                        }
                    )
                } catch TerminalArtifactReadContext.Error.forbidden {
                    #if DEBUG
                    return TerminalArtifactStatOutcome.forbidden(
                        diagnostics: context.authorizationDiagnostics()
                    )
                    #else
                    return TerminalArtifactStatOutcome.forbidden(diagnostics: "")
                    #endif
                }
            }.value
            switch outcome {
            case .success(let stat):
                return TerminalArtifactWire.result(stat)
            case .forbidden(let diagnostics):
                debugLogMobileTerminalArtifactDenial(op: "stat", path: context.requestedPath)
                #if DEBUG
                cmuxDebugLog("mobile.terminal.artifact.stat.deny \(diagnostics)")
                #endif
                return mobileTerminalArtifactError(.forbidden, path: context.requestedPath)
            }
        } catch let error as ArtifactByteReader.Error {
            return mobileArtifactReadFailure(error, path: context.requestedPath)
        } catch {
            return mobileArtifactReadFailure(.readFailed, path: context.requestedPath)
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
                let authorizedPath = try await Task.detached(priority: .utility) {
                    try context.authorizedRead { _, canonicalPath, identity in
                        (canonicalPath, identity)
                    }
                }.value
                return TerminalArtifactWire.result(
                    try await executionContext.issueArtifactTransfer(
                        canonicalPath: authorizedPath.0,
                        authorizedIdentity: authorizedPath.1
                    )
                )
            }
            let chunk = try await Task.detached(priority: .utility) {
                try context.authorizedRead { reader, canonicalPath, identity in
                    try reader.fetch(
                        path: canonicalPath,
                        offset: offset,
                        length: length,
                        authorizedCanonicalPath: canonicalPath,
                        authorizedIdentity: identity
                    )
                }
            }.value
            return TerminalArtifactWire.result(chunk)
        } catch let error as MobileHostIrohArtifactTransferRegistry.Error {
            switch error.issueFailure {
            case .fileNotFound:
                return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
            case .permissionDenied:
                return mobileArtifactReadFailure(.permissionDenied, path: context.requestedPath)
            case .notRegularFile:
                return mobileArtifactReadFailure(.notRegularFile, path: context.requestedPath)
            case .readFailed:
                return mobileArtifactReadFailure(.readFailed, path: context.requestedPath)
            case .unavailable:
                return mobileTerminalArtifactError(.unavailable, path: context.requestedPath)
            }
        } catch TerminalArtifactReadContext.Error.forbidden {
            debugLogMobileTerminalArtifactDenial(op: "fetch", path: context.requestedPath)
            return mobileTerminalArtifactError(.forbidden, path: context.requestedPath)
        } catch let error as ArtifactByteReader.Error {
            return mobileArtifactReadFailure(error, path: context.requestedPath)
        } catch {
            return mobileArtifactReadFailure(.readFailed, path: context.requestedPath)
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
                try context.authorizedRead { reader, canonicalPath, identity in
                    try reader.thumbnail(
                        path: canonicalPath,
                        maxDimension: maxDimension,
                        authorizedCanonicalPath: canonicalPath,
                        authorizedIdentity: identity
                    )
                }
            }.value
            return TerminalArtifactWire.result(thumbnail)
        } catch TerminalArtifactReadContext.Error.forbidden {
            debugLogMobileTerminalArtifactDenial(op: "thumbnail", path: context.requestedPath)
            return mobileTerminalArtifactError(.forbidden, path: context.requestedPath)
        } catch let error as ArtifactByteReader.Error {
            return mobileArtifactReadFailure(error, path: context.requestedPath)
        } catch {
            return mobileArtifactReadFailure(.previewFailed, path: context.requestedPath)
        }
    }

    func v2MobileTerminalArtifactList(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileTerminalArtifactContext(params: params, requiresPath: true)
        guard case .success(let context) = resolution else {
            return resolution.failureResult
        }
        do {
            let listing = try await Task.detached(priority: .utility) {
                try context.authorizedDirectoryList { reader, canonicalPath, identity in
                    try reader.list(
                        path: canonicalPath,
                        authorizedCanonicalPath: canonicalPath,
                        authorizedIdentity: identity
                    )
                }
            }.value
            return TerminalArtifactWire.result(listing)
        } catch TerminalArtifactReadContext.Error.forbidden {
            debugLogMobileTerminalArtifactDenial(op: "list", path: context.requestedPath)
            return mobileTerminalArtifactError(.forbidden, path: context.requestedPath)
        } catch let error as ArtifactByteReader.Error {
            return mobileArtifactReadFailure(error, path: context.requestedPath)
        } catch {
            return mobileArtifactReadFailure(.readFailed, path: context.requestedPath)
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
        let scanAuthorizedIdentities = requiresPath
            ? await terminalArtifactAuthorizationStore.authorizedIdentities(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
            : [:]
        let directoryAccessMode = mobileArtifactDirectoryAccessMode()
        return v2MainSync { () -> TerminalArtifactContextResolution in
            guard let resolved = mobileCanonicalTerminalTarget(params: params) else {
                return .failure(mobileTerminalArtifactError(.notFound, path: v2RawString(params, "path")))
            }
            let resolvedSurfaceID = resolved.surfaceID
            let terminalTarget = resolved.target
            let terminalPanel = terminalTarget.panel
            let workingDirectory: String?
            if terminalTarget.bindingState == .registryRebound {
                // Text and relative-path authority must come from the same
                // runtime during a replacement overlap. Structural workspace
                // metadata still belongs to the outgoing panel, so fail closed
                // when the canonical surface has no directory of its own.
                workingDirectory = mobileNonEmpty(terminalTarget.surface.reportedWorkingDirectory)
                    ?? mobileNonEmpty(terminalTarget.surface.requestedWorkingDirectory)
            } else {
                workingDirectory = resolved.workspace.effectivePanelDirectory(
                    panelId: resolvedSurfaceID,
                    localFallback: mobileNonEmpty(terminalPanel.directory)
                        ?? mobileNonEmpty(terminalPanel.requestedWorkingDirectory)
                ) ?? resolved.workspace.currentDirectory
            }
            let terminalText = includeTerminalText
                ? readTerminalTextForSnapshot(
                    terminalTarget: terminalTarget,
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
                scanAuthorizedIdentities: scanAuthorizedIdentities,
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
                code: "terminal_not_found",
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

private enum TerminalArtifactStatOutcome: Sendable {
    case success(ChatArtifactStat)
    case forbidden(diagnostics: String)
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
    private let scanAuthorizedIdentities: [String: ChatArtifactFileIdentity]
    private let directoryAccessMode: ChatArtifactScope.DirectoryAccessMode

    init(
        workspaceID: String,
        surfaceID: String,
        terminalText: String,
        workingDirectory: String?,
        requestedPath: String?,
        sessionID: String?,
        scanAuthorizedPaths: Set<String>,
        scanAuthorizedIdentities: [String: ChatArtifactFileIdentity],
        directoryAccessMode: ChatArtifactScope.DirectoryAccessMode
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.terminalText = terminalText
        self.workingDirectory = workingDirectory
        self.requestedPath = requestedPath
        self.sessionID = sessionID
        self.scanAuthorizedPaths = scanAuthorizedPaths
        self.scanAuthorizedIdentities = scanAuthorizedIdentities
        self.directoryAccessMode = directoryAccessMode
    }

    func scan(
        includeDirectories: Bool
    ) -> (response: TerminalArtifactScanResponse, identities: [String: ChatArtifactFileIdentity]) {
        let reader = ArtifactByteReader()
        let scope = TerminalArtifactScope(
            terminalText: terminalText,
            workingDirectory: workingDirectory,
            resolver: ChatArtifactScope.FoundationResolver(),
            directoryAccessMode: directoryAccessMode
        )
        var identities: [String: ChatArtifactFileIdentity] = [:]
        let artifacts = scope.artifactPaths(limit: 200).compactMap { path -> TerminalArtifactReference? in
            guard let stat = try? reader.stat(path: path) else { return nil }
            guard includeDirectories || !stat.isDirectory else { return nil }
            if let identity = try? reader.identity(
                path: path,
                authorizedCanonicalPath: path
            ) {
                identities[path] = identity
            }
            return TerminalArtifactReference(
                path: path,
                kind: stat.kind,
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                size: stat.size,
                modifiedAt: stat.modifiedAt
            )
        }
        return (
            TerminalArtifactScanResponse(artifacts: artifacts, sessionID: sessionID),
            identities
        )
    }

    func authorizedRead<T>(
        _ operation: (ArtifactByteReader, String, ChatArtifactFileIdentity) throws -> T
    ) throws -> T {
        guard let requestedPath else { throw Error.forbidden }
        let resolver = ChatArtifactScope.FoundationResolver()
        let snapshotScope = ChatArtifactScope(
            referencedPaths: scanAuthorizedPaths,
            directoryAccessMode: directoryAccessMode,
            resolver: resolver
        )
        if let canonicalPath = snapshotScope.canonicalFilePath(for: requestedPath) {
            let identity = try authorizedIdentity(
                for: canonicalPath,
                requireStored: scanAuthorizedPaths.contains(canonicalPath)
            )
            return try operation(ArtifactByteReader(), canonicalPath, identity)
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
        let identity = try authorizedIdentity(for: canonicalPath)
        return try operation(ArtifactByteReader(), canonicalPath, identity)
    }

    /// Stat may be answered for any path the scope would let the client list,
    /// because listing already reveals more than the directory's own metadata.
    func authorizedStat<T>(
        _ operation: (ArtifactByteReader, String, ChatArtifactFileIdentity) throws -> T
    ) throws -> T {
        guard let requestedPath else { throw Error.forbidden }
        let resolver = ChatArtifactScope.FoundationResolver()
        let snapshotScope = ChatArtifactScope(
            referencedPaths: scanAuthorizedPaths,
            directoryAccessMode: directoryAccessMode,
            resolver: resolver
        )
        if let canonicalPath = snapshotScope.canonicalFilePath(for: requestedPath) {
            let identity = try authorizedIdentity(
                for: canonicalPath,
                requireStored: scanAuthorizedPaths.contains(canonicalPath)
            )
            return try operation(ArtifactByteReader(), canonicalPath, identity)
        }
        if let canonicalPath = snapshotScope.canonicalDirectoryListPath(for: requestedPath) {
            let identity = try authorizedIdentity(
                for: canonicalPath,
                requireStored: scanAuthorizedPaths.contains(canonicalPath)
            )
            return try operation(ArtifactByteReader(), canonicalPath, identity)
        }
        let scope = TerminalArtifactScope(
            terminalText: terminalText,
            workingDirectory: workingDirectory,
            resolver: resolver,
            directoryAccessMode: directoryAccessMode
        )
        if let canonicalPath = scope.canonicalPath(for: requestedPath) {
            let identity = try authorizedIdentity(for: canonicalPath)
            return try operation(ArtifactByteReader(), canonicalPath, identity)
        }
        guard let canonicalPath = scope.canonicalDirectoryListPath(for: requestedPath) else {
            throw Error.forbidden
        }
        let identity = try authorizedIdentity(for: canonicalPath)
        return try operation(ArtifactByteReader(), canonicalPath, identity)
    }

    /// Explains why a stat authorization denied, for the DEBUG denial log.
    /// Reports input shape (text size, scan-path count) and which
    /// canonicalization branches matched, never path contents.
    func authorizationDiagnostics() -> String {
        guard let requestedPath else { return "path=nil" }
        let resolver = ChatArtifactScope.FoundationResolver()
        let snapshotScope = ChatArtifactScope(
            referencedPaths: scanAuthorizedPaths,
            directoryAccessMode: directoryAccessMode,
            resolver: resolver
        )
        let scope = TerminalArtifactScope(
            terminalText: terminalText,
            workingDirectory: workingDirectory,
            resolver: resolver,
            directoryAccessMode: directoryAccessMode
        )
        let detected = TerminalArtifactPathDetector().paths(in: terminalText)
        return "textChars=\(terminalText.count)"
            + " detected=\(detected.count)"
            + " scanPaths=\(scanAuthorizedPaths.count)"
            + " cwdSet=\(workingDirectory != nil)"
            + " mode=\(directoryAccessMode.rawValue)"
            + " snapFile=\(snapshotScope.canonicalFilePath(for: requestedPath) != nil)"
            + " snapDir=\(snapshotScope.canonicalDirectoryListPath(for: requestedPath) != nil)"
            + " liveFile=\(scope.canonicalPath(for: requestedPath) != nil)"
            + " liveDir=\(scope.canonicalDirectoryListPath(for: requestedPath) != nil)"
    }

    func authorizedDirectoryList<T>(
        _ operation: (ArtifactByteReader, String, ChatArtifactFileIdentity) throws -> T
    ) throws -> T {
        guard let requestedPath else { throw Error.forbidden }
        let resolver = ChatArtifactScope.FoundationResolver()
        let snapshotScope = ChatArtifactScope(
            referencedPaths: scanAuthorizedPaths,
            directoryAccessMode: directoryAccessMode,
            resolver: resolver
        )
        if let canonicalPath = snapshotScope.canonicalDirectoryListPath(for: requestedPath) {
            let identity = try authorizedIdentity(
                for: canonicalPath,
                requireStored: scanAuthorizedPaths.contains(canonicalPath)
            )
            return try operation(ArtifactByteReader(), canonicalPath, identity)
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
        let identity = try authorizedIdentity(for: canonicalPath)
        return try operation(ArtifactByteReader(), canonicalPath, identity)
    }

    private func authorizedIdentity(
        for canonicalPath: String,
        requireStored: Bool = false
    ) throws -> ChatArtifactFileIdentity {
        if let identity = scanAuthorizedIdentities[canonicalPath] {
            return identity
        }
        guard !requireStored else { throw Error.forbidden }
        return try ArtifactByteReader().identity(
            path: canonicalPath,
            authorizedCanonicalPath: canonicalPath
        )
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
