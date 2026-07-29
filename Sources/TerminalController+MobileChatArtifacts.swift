import CmuxAgentChat
import CmuxSettings
import Foundation

private enum TerminalControllerChatArtifactIndexProvider {
    static let shared = AgentChatArtifactIndex()
    static let ordering = ChatArtifactGalleryOrderingCache()
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
            guard let indexedSession = try await mobileChatArtifactIndexedSession(sessionID: sessionID) else {
                return mobileChatArtifactError(.notFound, path: "")
            }
            let pageSize = min(max(v2Int(params, "page_size") ?? 60, 1), 100)
            let query = v2RawString(params, "query")
            let includeDirectories = v2Bool(params, "include_directories") ?? false
            let orderedItems = await TerminalControllerChatArtifactIndexProvider.ordering.ordered(
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
            return .ok(ChatArtifactWire.payload(page) ?? [:])
        } catch {
            return mobileChatArtifactError(.notFound, path: "")
        }
    }

    /// Resolves and derives the same authorized transcript snapshot used by
    /// both gallery pages and terminal-bound count-only scans.
    func mobileChatArtifactIndexedSession(
        sessionID: String
    ) async throws -> (sessionID: String, snapshot: AgentChatArtifactIndex.Snapshot)? {
        guard let service = agentChatTranscriptService,
              let record = service.sessionRecord(sessionID: sessionID),
              let transcriptPath = service.resolver.transcriptPath(for: record) else {
            return nil
        }
        let snapshot = try await TerminalControllerChatArtifactIndexProvider.shared.snapshot(
            sessionID: record.sessionID,
            agentKind: record.agentKind,
            transcriptPath: transcriptPath,
            workingDirectory: record.workingDirectory
        )
        return (record.sessionID, snapshot)
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
            return .ok(ChatArtifactWire.payload(stat) ?? [:])
        } catch ArtifactByteReader.Error.fileNotFound {
            debugLogMobileChatArtifactDenial(
                code: "file_not_found", reason: "stat-failed", path: resolved.requestedPath
            )
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        } catch ArtifactByteReader.Error.unsupportedMedia {
            return mobileChatArtifactError(.unsupportedMedia, path: resolved.requestedPath)
        } catch {
            debugLogMobileChatArtifactDenial(
                code: "file_not_found", reason: "stat-failed", path: resolved.requestedPath
            )
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
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
                return .ok(ChatArtifactWire.payload(
                    try await executionContext.issueArtifactTransfer(
                        canonicalPath: resolved.canonicalPath
                    )
                ) ?? [:])
            }
            let chunk = try await Task.detached {
                try ArtifactByteReader().fetch(path: resolved.canonicalPath, offset: offset, length: length)
            }.value
            return .ok(ChatArtifactWire.payload(chunk) ?? [:])
        } catch let error as MobileHostIrohArtifactTransferRegistry.Error {
            switch error.issueFailure {
            case .fileNotFound:
                debugLogMobileChatArtifactDenial(
                    code: "file_not_found",
                    reason: "descriptor-file-invalid",
                    path: resolved.requestedPath
                )
                return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
            case .unavailable:
                debugLogMobileChatArtifactDenial(
                    code: "unavailable",
                    reason: "descriptor-issue-failed",
                    path: resolved.requestedPath
                )
                return mobileChatArtifactError(.unavailable, path: resolved.requestedPath)
            }
        } catch ArtifactByteReader.Error.fileNotFound {
            debugLogMobileChatArtifactDenial(
                code: "file_not_found", reason: "stat-failed", path: resolved.requestedPath
            )
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        } catch {
            debugLogMobileChatArtifactDenial(
                code: "file_not_found", reason: "stat-failed", path: resolved.requestedPath
            )
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
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
            return .ok(ChatArtifactWire.payload(thumbnail) ?? [:])
        } catch ArtifactByteReader.Error.unsupportedMedia {
            return mobileChatArtifactError(.unsupportedMedia, path: resolved.requestedPath)
        } catch ArtifactByteReader.Error.fileNotFound {
            debugLogMobileChatArtifactDenial(
                code: "file_not_found", reason: "stat-failed", path: resolved.requestedPath
            )
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        } catch {
            return mobileChatArtifactError(.unsupportedMedia, path: resolved.requestedPath)
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
            return .ok(ChatArtifactWire.payload(listing) ?? [:])
        } catch ArtifactByteReader.Error.fileNotFound {
            debugLogMobileChatArtifactDenial(
                code: "file_not_found", reason: "stat-failed", path: resolved.requestedPath
            )
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        } catch {
            debugLogMobileChatArtifactDenial(
                code: "file_not_found", reason: "stat-failed", path: resolved.requestedPath
            )
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        }
    }

    private enum ChatArtifactOperation {
        case file
        case list

        var indexOperation: AgentChatArtifactIndex.Operation {
            switch self {
            case .file:
                return .file
            case .list:
                return .list
            }
        }
    }

    private struct ResolvedChatArtifact: Sendable {
        let requestedPath: String
        let canonicalPath: String
    }

    private enum ChatArtifactResolution {
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

    private func mobileChatArtifactResolution(
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
        guard let record = service.sessionRecord(sessionID: sessionID) else {
            return .failure(mobileChatArtifactError(.notFound, path: requestedPath))
        }
        guard let transcriptPath = service.resolver.transcriptPath(for: record) else {
            return .failure(mobileChatArtifactError(.notFound, path: requestedPath))
        }
        do {
            let pathResult = try await TerminalControllerChatArtifactIndexProvider.shared.canonicalPath(
                sessionID: record.sessionID,
                agentKind: record.agentKind,
                transcriptPath: transcriptPath,
                workingDirectory: record.workingDirectory,
                requestedPath: requestedPath,
                operation: operation.indexOperation,
                directoryAccessMode: mobileArtifactDirectoryAccessMode()
            )
            switch pathResult {
            case .success(let canonicalPath):
                return .success(ResolvedChatArtifact(
                    requestedPath: requestedPath,
                    canonicalPath: canonicalPath
                ))
            case .canonicalizationFailed:
                debugLogMobileChatArtifactDenial(
                    code: "forbidden", reason: "canonicalization-failed", path: requestedPath
                )
                return .failure(mobileChatArtifactError(.forbidden, path: requestedPath))
            case .notInSet:
                debugLogMobileChatArtifactDenial(
                    code: "forbidden", reason: "not-in-set", path: requestedPath
                )
                return .failure(mobileChatArtifactError(.forbidden, path: requestedPath))
            }
        } catch {
            return .failure(mobileChatArtifactError(.notFound, path: requestedPath))
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
                code: "not_found",
                message: String(
                    localized: "mobile.chat.artifact.error.sessionNotFound",
                    defaultValue: "That agent session is no longer available."
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
}

private struct ChatArtifactWire {
    static func payload<T: Encodable>(_ value: T) -> [String: Any]? {
        let coding = ChatWireCoding()
        guard let data = try? coding.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
