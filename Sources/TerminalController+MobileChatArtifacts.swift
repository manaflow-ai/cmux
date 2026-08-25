import CmuxAgentChat
import CmuxArtifacts
import CmuxSettings
import Foundation

private enum TerminalControllerChatArtifactIndexProvider {
    static let shared = AgentChatArtifactIndex()
    static let ordering = ChatArtifactGalleryOrderingCache()
    static let rowCounts = ChatArtifactGalleryRowCountCache(maximumAge: 2)
}

private enum MobileChatArtifactIndexError: Error {
    case unavailable
    case sessionNotFound
    case sessionUnavailable
}

extension TerminalController {
    func v2MobileChatArtifactGallery(params: [String: Any]) async -> V2CallResult {
        guard let sessionID = v2RawString(params, "session_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "mobile.chat.artifact.error.galleryInvalidParams",
                    defaultValue: "session_id is required."
                ),
                data: nil
            )
        }
        let cursorToken = v2RawString(params, "cursor")
        let cursor: ChatArtifactGalleryCursor?
        if let cursorToken {
            guard let decoded = ChatArtifactGalleryCursor(token: cursorToken) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "mobile.chat.artifact.error.invalidCursor",
                        defaultValue: "The gallery cursor is invalid."
                    ),
                    data: nil
                )
            }
            cursor = decoded
        } else {
            cursor = nil
        }
        do {
            let indexedSession = try await mobileChatArtifactIndexedSession(sessionID: sessionID)
            let pageSize = min(max(v2Int(params, "page_size") ?? 60, 1), 100)
            let query = v2RawString(params, "query")
            let includeDirectories = v2Bool(params, "include_directories") ?? false
            guard let service = agentChatTranscriptService else {
                return mobileChatArtifactError(.notFound, path: "")
            }
            let orderedItems = await service.artifactGalleryOrderingCache.ordered(
                indexedSession.snapshot.artifacts,
                indexID: indexedSession.sessionID,
                generation: indexedSession.snapshot.generation
            )
            let page = await Task.detached(priority: .utility) {
                AgentChatArtifactGalleryBuilder().page(
                    sessionID: indexedSession.sessionID,
                    items: indexedSession.snapshot.artifacts,
                    orderedItems: orderedItems,
                    generation: indexedSession.snapshot.generation,
                    cursor: cursor,
                    pageSize: pageSize,
                    query: query,
                    includeDirectories: includeDirectories
                )
            }.value
            return ChatArtifactWire.result(page)
        } catch MobileChatArtifactIndexError.unavailable {
            return mobileChatArtifactError(.unavailable, path: "")
        } catch MobileChatArtifactIndexError.sessionNotFound {
            return mobileChatArtifactError(.notFound, path: "")
        } catch {
            return mobileChatArtifactError(.sessionUnavailable, path: "")
        }
    }

    /// Resolves and derives the same authorized transcript snapshot used by
    /// both gallery pages and terminal-bound count-only scans.
    func mobileChatArtifactIndexedSession(
        sessionID: String
    ) async throws -> (sessionID: String, snapshot: AgentChatArtifactIndex.Snapshot) {
        guard let service = agentChatTranscriptService else {
            throw MobileChatArtifactIndexError.unavailable
        }
        let resolved: (record: AgentChatSessionRecord, path: String)
        do {
            guard let transcript = try await service.resolvedTranscript(sessionID: sessionID) else {
                throw MobileChatArtifactIndexError.sessionNotFound
            }
            resolved = transcript
        } catch let error as MobileChatArtifactIndexError {
            throw error
        } catch {
            throw MobileChatArtifactIndexError.sessionUnavailable
        }
        let snapshot = try await service.artifactIndex.snapshot(
            sessionID: resolved.record.sessionID,
            agentKind: resolved.record.agentKind,
            transcriptPath: resolved.path,
            workingDirectory: resolved.record.workingDirectory
        )
        service.scheduleIndexedArtifactCapture(record: resolved.record, snapshot: snapshot)
        return (resolved.record.sessionID, snapshot)
    }

    /// Returns the stat-filtered count for the gallery's default landing view.
    func mobileChatArtifactGalleryRowTotal(
        sessionID: String,
        generation: String,
        artifacts: [ChatArtifactIndexedReference],
        includeDirectories: Bool,
        includeMissing: Bool
    ) async -> Int {
        // Counting is order-independent, so the ordering cache is skipped;
        // the sweep is existence-only over the raw snapshot, runs off the
        // caller inside the cache actor, and concurrent misses on the same
        // (session, generation, filters) key share one computation.
        guard let service = agentChatTranscriptService else { return 0 }
        return await service.artifactGalleryRowCountCache.total(
            sessionID: sessionID,
            generation: generation,
            includeDirectories: includeDirectories,
            includeMissing: includeMissing,
            now: Date()
        ) {
            ChatArtifactGalleryRowEligibility().defaultRowCount(
                artifacts,
                includeDirectories: includeDirectories,
                includeMissing: includeMissing
            )
        }
    }

    func v2MobileChatArtifactStat(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileChatArtifactResolution(params: params, operation: .file)
        guard case .success(let resolved) = resolution else {
            return resolution.failureResult
        }
        do {
            let stat = try await Task.detached {
                try ArtifactByteReader().stat(path: resolved.canonicalPath)
            }.value
            return ChatArtifactWire.result(stat)
        } catch let error as ArtifactByteReader.Error {
            return mobileArtifactReadFailure(error, path: resolved.requestedPath)
        } catch {
            debugLogMobileChatArtifactDenial(
                code: "read_failed", reason: "stat-failed", path: resolved.requestedPath
            )
            return mobileArtifactReadFailure(.readFailed, path: resolved.requestedPath)
        }
    }

    func v2MobileChatArtifactFetch(
        params: [String: Any],
        executionContext: MobileHostRPCExecutionContext? = nil
    ) async -> V2CallResult {
        let resolution = await mobileChatArtifactResolution(params: params, operation: .file)
        guard case .success(let resolved) = resolution else {
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
                return ChatArtifactWire.result(
                    try await executionContext.issueArtifactTransfer(
                        canonicalPath: resolved.canonicalPath
                    )
                )
            }
            let chunk = try await Task.detached {
                try ArtifactByteReader().fetch(path: resolved.canonicalPath, offset: offset, length: length)
            }.value
            return ChatArtifactWire.result(chunk)
        } catch let error as MobileHostIrohArtifactTransferRegistry.Error {
            switch error.issueFailure {
            case .fileNotFound:
                debugLogMobileChatArtifactDenial(
                    code: "file_not_found",
                    reason: "descriptor-file-invalid",
                    path: resolved.requestedPath
                )
                return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
            case .permissionDenied:
                return mobileArtifactReadFailure(.permissionDenied, path: resolved.requestedPath)
            case .notRegularFile:
                return mobileArtifactReadFailure(.notRegularFile, path: resolved.requestedPath)
            case .readFailed:
                return mobileArtifactReadFailure(.readFailed, path: resolved.requestedPath)
            case .unavailable:
                debugLogMobileChatArtifactDenial(
                    code: "unavailable",
                    reason: "descriptor-issue-failed",
                    path: resolved.requestedPath
                )
                return mobileChatArtifactError(.unavailable, path: resolved.requestedPath)
            }
        } catch let error as ArtifactByteReader.Error {
            return mobileArtifactReadFailure(error, path: resolved.requestedPath)
        } catch {
            debugLogMobileChatArtifactDenial(
                code: "read_failed", reason: "fetch-failed", path: resolved.requestedPath
            )
            return mobileArtifactReadFailure(.readFailed, path: resolved.requestedPath)
        }
    }

    func v2MobileChatArtifactThumbnail(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileChatArtifactResolution(params: params, operation: .file)
        guard case .success(let resolved) = resolution else {
            return resolution.failureResult
        }
        let maxDimension = min(max(v2Int(params, "max_dimension") ?? 512, 64), 1024)
        do {
            let thumbnail = try await Task.detached {
                try ArtifactByteReader().thumbnail(path: resolved.canonicalPath, maxDimension: maxDimension)
            }.value
            return ChatArtifactWire.result(thumbnail)
        } catch let error as ArtifactByteReader.Error {
            return mobileArtifactReadFailure(error, path: resolved.requestedPath)
        } catch {
            return mobileArtifactReadFailure(.previewFailed, path: resolved.requestedPath)
        }
    }

    func v2MobileChatArtifactList(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileChatArtifactResolution(params: params, operation: .list)
        guard case .success(let resolved) = resolution else {
            return resolution.failureResult
        }
        do {
            let listing = try await Task.detached {
                try ArtifactByteReader().list(path: resolved.canonicalPath)
            }.value
            return ChatArtifactWire.result(listing)
        } catch let error as ArtifactByteReader.Error {
            return mobileArtifactReadFailure(error, path: resolved.requestedPath)
        } catch {
            debugLogMobileChatArtifactDenial(
                code: "read_failed", reason: "list-failed", path: resolved.requestedPath
            )
            return mobileArtifactReadFailure(.readFailed, path: resolved.requestedPath)
        }
    }

    func v2MobileChatArtifactSave(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileChatArtifactResolution(params: params, operation: .save)
        guard case .success(let resolved) = resolution else {
            return resolution.failureResult
        }
        return await v2MobileChatArtifactSave(resolved: resolved)
    }

    func v2MobileChatArtifactSave(resolved: ResolvedChatArtifact) async -> V2CallResult {
        guard let service = agentChatTranscriptService else {
            return mobileChatArtifactError(.notFound, path: resolved.requestedPath)
        }
        do {
            guard let captureContext = resolved.authorizedCaptureContext else {
                throw AgentArtifactCaptureSaveError.rejected
            }
            let result = try await service.saveArtifact(
                context: captureContext,
                sourceURL: URL(fileURLWithPath: resolved.canonicalPath, isDirectory: false)
            )
            return .ok(ChatArtifactWire.payload(result) ?? [:])
        } catch {
            return .err(
                code: "artifact_save_failed",
                message: String(
                    localized: "mobile.chat.artifact.error.saveFailed",
                    defaultValue: "The file could not be saved to this project’s Artifacts."
                ),
                data: ["path": resolved.requestedPath]
            )
        }
    }

    enum ChatArtifactOperation: Sendable {
        case file
        case list
        case save

        var indexOperation: AgentChatArtifactIndex.Operation {
            switch self {
            case .file, .save:
                return .file
            case .list:
                return .list
            }
        }

        var resolvesCaptureProject: Bool {
            if case .save = self { return true }
            return false
        }
    }

    struct ResolvedChatArtifact: Sendable {
        let authorizedCaptureContext: ArtifactCaptureContext?
        let requestedPath: String
        let canonicalPath: String
    }

    enum ChatArtifactResolution {
        case success(ResolvedChatArtifact)
        case failure(V2CallResult)

        var failureResult: V2CallResult {
            switch self {
            case .success:
                return .err(code: "internal_error", message: "unexpected success", data: nil)
            case .failure(let result):
                return result
            }
        }
    }

    func mobileChatArtifactResolution(
        params: [String: Any],
        operation: ChatArtifactOperation
    ) async -> ChatArtifactResolution {
        guard let sessionID = v2RawString(params, "session_id"),
              let requestedPath = v2RawString(params, "path"),
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !requestedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.err(
                code: "invalid_params",
                message: String(
                    localized: "mobile.chat.artifact.error.invalidParams",
                    defaultValue: "session_id and path are required."
                ),
                data: nil
            ))
        }
        guard let service = agentChatTranscriptService else {
            return .failure(.err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil))
        }
        let resolved: (record: AgentChatSessionRecord, path: String)
        do {
            guard let transcript = try await service.resolvedTranscript(sessionID: sessionID) else {
                return .failure(mobileChatArtifactError(.notFound, path: requestedPath))
            }
            resolved = transcript
        } catch {
            return .failure(mobileChatArtifactError(.sessionUnavailable, path: requestedPath))
        }
        do {
            let pathResult = try await service.artifactIndex.canonicalPath(
                sessionID: resolved.record.sessionID,
                agentKind: resolved.record.agentKind,
                transcriptPath: resolved.path,
                workingDirectory: resolved.record.workingDirectory,
                requestedPath: requestedPath,
                operation: operation.indexOperation,
                directoryAccessMode: mobileArtifactDirectoryAccessMode()
            )
            switch pathResult {
            case .success(let canonicalPath):
                let captureContext = operation.resolvesCaptureProject
                    ? await service.artifactCaptureContext(for: resolved.record)
                    : nil
                return .success(ResolvedChatArtifact(
                    authorizedCaptureContext: captureContext,
                    requestedPath: requestedPath,
                    canonicalPath: canonicalPath
                ))
            case .canonicalizationFailed:
                debugLogMobileChatArtifactDenial(
                    code: "invalid_params", reason: "canonicalization-failed", path: requestedPath
                )
                return .failure(.err(
                    code: "invalid_params",
                    message: String(
                        localized: "mobile.chat.artifact.error.invalidPath",
                        defaultValue: "The file path is invalid."
                    ),
                    data: ["path": requestedPath]
                ))
            case .notInSet:
                debugLogMobileChatArtifactDenial(
                    code: "forbidden", reason: "not-in-set", path: requestedPath
                )
                return .failure(mobileChatArtifactError(.forbidden, path: requestedPath))
            }
        } catch {
            return .failure(mobileChatArtifactError(.sessionUnavailable, path: requestedPath))
        }
    }

    /// Resolves the persisted mobile folder setting into the shared scope policy.
    func mobileArtifactDirectoryAccessMode(
        defaults: UserDefaults = .standard
    ) -> ChatArtifactScope.DirectoryAccessMode {
        let key = SettingCatalog().mobile.artifactFolderAccess
        let setting = MobileArtifactFolderAccess.decodeFromUserDefaults(
            defaults.object(forKey: key.userDefaultsKey)
        ) ?? key.defaultValue
        switch setting {
        case .subtree:
            return .subtree
        case .oneLevel:
            return .oneLevel
        }
    }

    private func debugLogMobileChatArtifactDenial(code: String, reason: String, path: String) {
        #if DEBUG
        cmuxDebugLog("mobile.chat.artifact.deny code=\(code) reason=\(reason) path=\(path)")
        #endif
    }

    private enum MobileChatArtifactErrorKind {
        case notFound
        case sessionUnavailable
        case forbidden
        case fileNotFound
        case unsupportedMedia
        case unavailable
    }

    private func mobileChatArtifactError(
        _ kind: MobileChatArtifactErrorKind,
        path: String
    ) -> V2CallResult {
        switch kind {
        case .notFound:
            return .err(
                code: "session_not_found",
                message: String(
                    localized: "mobile.chat.artifact.error.sessionNotFound",
                    defaultValue: "That agent session is no longer available."
                ),
                data: nil
            )
        case .sessionUnavailable:
            return .err(
                code: "session_unavailable",
                message: String(
                    localized: "mobile.chat.artifact.error.sessionUnavailable",
                    defaultValue: "That session exists, but its file history could not be read."
                ),
                data: nil
            )
        case .forbidden:
            return .err(
                code: "forbidden",
                message: String(
                    localized: "mobile.chat.artifact.error.forbidden",
                    defaultValue: "That file was not referenced by this conversation."
                ),
                data: ["path": path]
            )
        case .fileNotFound:
            return .err(
                code: "file_not_found",
                message: String(
                    localized: "mobile.chat.artifact.error.fileNotFound",
                    defaultValue: "That file is no longer available on the Mac."
                ),
                data: ["path": path]
            )
        case .unsupportedMedia:
            return .err(
                code: "unsupported_media",
                message: String(
                    localized: "mobile.chat.artifact.error.unsupportedMedia",
                    defaultValue: "This file type cannot be previewed."
                ),
                data: ["path": path]
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

    func mobileArtifactReadFailure(
        _ error: ArtifactByteReader.Error,
        path: String?
    ) -> V2CallResult {
        let data = path.map { ["path": $0] }
        switch error {
        case .fileNotFound:
            return .err(
                code: "file_not_found",
                message: String(
                    localized: "mobile.chat.artifact.error.fileNotFound",
                    defaultValue: "That file is no longer available on the Mac."
                ),
                data: data
            )
        case .permissionDenied:
            return .err(
                code: "permission_denied",
                message: String(
                    localized: "mobile.chat.artifact.error.permissionDenied",
                    defaultValue: "cmux does not have permission to read that file."
                ),
                data: data
            )
        case .notDirectory:
            return .err(
                code: "not_directory",
                message: String(
                    localized: "mobile.chat.artifact.error.notDirectory",
                    defaultValue: "That path is not a folder."
                ),
                data: data
            )
        case .notRegularFile:
            return .err(
                code: "not_regular_file",
                message: String(
                    localized: "mobile.chat.artifact.error.notRegularFile",
                    defaultValue: "That path is not a regular file."
                ),
                data: data
            )
        case .unsupportedMedia:
            return .err(
                code: "unsupported_media",
                message: String(
                    localized: "mobile.chat.artifact.error.unsupportedMedia",
                    defaultValue: "This file type cannot be previewed."
                ),
                data: data
            )
        case .corruptMedia:
            return .err(
                code: "corrupt_media",
                message: String(
                    localized: "mobile.chat.artifact.error.corruptMedia",
                    defaultValue: "The file contains invalid or damaged media data."
                ),
                data: data
            )
        case .previewFailed:
            return .err(
                code: "preview_failed",
                message: String(
                    localized: "mobile.chat.artifact.error.previewFailed",
                    defaultValue: "The Mac could not create a preview for that file."
                ),
                data: data
            )
        case .readFailed:
            return .err(
                code: "read_failed",
                message: String(
                    localized: "mobile.chat.artifact.error.readFailed",
                    defaultValue: "The Mac found that file but could not read it."
                ),
                data: data
            )
        }
    }
}

private struct ChatArtifactWire {
    static func result<T: Encodable>(_ value: T) -> TerminalController.V2CallResult {
        let coding = ChatWireCoding()
        guard let data = try? coding.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .err(
                code: "internal_error",
                message: "Failed to encode chat artifact response",
                data: nil
            )
        }
        return .ok(object)
    }
}
