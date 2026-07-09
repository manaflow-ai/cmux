import CmuxAgentChat
import Foundation

private enum TerminalControllerChatArtifactIndexProvider {
    static let shared = AgentChatArtifactIndex()
}

extension TerminalController {
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
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        } catch ArtifactByteReader.Error.unsupportedMedia {
            return mobileChatArtifactError(.unsupportedMedia, path: resolved.requestedPath)
        } catch {
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        }
    }

    func v2MobileChatArtifactFetch(params: [String: Any]) async -> V2CallResult {
        let resolution = await mobileChatArtifactResolution(params: params, operation: .file)
        guard case .success(let resolved) = resolution else {
            return resolution.failureResult
        }
        let offset = max(0, Int64(v2Int(params, "offset") ?? 0))
        let length = ChatArtifactTransferPolicy.defaultPolicy
            .clampedChunkLength(v2Int(params, "length"))
        do {
            let chunk = try await Task.detached {
                try ArtifactByteReader().fetch(path: resolved.canonicalPath, offset: offset, length: length)
            }.value
            return .ok(ChatArtifactWire.payload(chunk) ?? [:])
        } catch ArtifactByteReader.Error.fileNotFound {
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        } catch {
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
            return mobileChatArtifactError(.fileNotFound, path: resolved.requestedPath)
        } catch {
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
            let canonicalPath = try await TerminalControllerChatArtifactIndexProvider.shared.canonicalPath(
                sessionID: record.sessionID,
                agentKind: record.agentKind,
                transcriptPath: transcriptPath,
                requestedPath: requestedPath,
                operation: operation.indexOperation
            )
            guard let canonicalPath else {
                return .failure(mobileChatArtifactError(.forbidden, path: requestedPath))
            }
            return .success(ResolvedChatArtifact(requestedPath: requestedPath, canonicalPath: canonicalPath))
        } catch {
            return .failure(mobileChatArtifactError(.notFound, path: requestedPath))
        }
    }

    private enum MobileChatArtifactErrorKind {
        case notFound
        case forbidden
        case fileNotFound
        case unsupportedMedia
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
