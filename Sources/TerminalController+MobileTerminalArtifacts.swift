import CmuxAgentChat
import Foundation

extension TerminalController {
    func v2MobileTerminalArtifactDispatch(method: String, params: [String: Any]) async -> V2CallResult {
        switch method {
        case "mobile.terminal.artifact.scan":
            return await v2MobileTerminalArtifactScan(params: params)
        case "mobile.terminal.artifact.stat":
            return await v2MobileTerminalArtifactStat(params: params)
        case "mobile.terminal.artifact.fetch":
            return await v2MobileTerminalArtifactFetch(params: params)
        case "mobile.terminal.artifact.thumbnail":
            return await v2MobileTerminalArtifactThumbnail(params: params)
        default:
            return .err(code: "method_not_found", message: "Unknown mobile terminal artifact method", data: nil)
        }
    }

    func v2MobileTerminalArtifactScan(params: [String: Any]) async -> V2CallResult {
        let resolution = mobileTerminalArtifactContext(params: params, requiresPath: false)
        guard case .success(let context) = resolution else {
            return resolution.failureResult
        }
        let response = await Task.detached(priority: .utility) {
            context.scan()
        }.value
        return .ok(TerminalArtifactWire.payload(response) ?? [:])
    }

    func v2MobileTerminalArtifactStat(params: [String: Any]) async -> V2CallResult {
        let resolution = mobileTerminalArtifactContext(params: params, requiresPath: true)
        guard case .success(let context) = resolution else {
            return resolution.failureResult
        }
        do {
            let stat = try await Task.detached(priority: .utility) {
                try context.authorizedRead { reader, canonicalPath in
                    try reader.stat(path: canonicalPath)
                }
            }.value
            return .ok(TerminalArtifactWire.payload(stat) ?? [:])
        } catch TerminalArtifactReadContext.Error.forbidden {
            cmuxDebugLog("mobile.terminal.artifact.forbidden op=stat path=\(context.requestedPath ?? "nil")")
            return mobileTerminalArtifactError(.forbidden, path: context.requestedPath)
        } catch ArtifactByteReader.Error.fileNotFound {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        } catch ArtifactByteReader.Error.unsupportedMedia {
            return mobileTerminalArtifactError(.unsupportedMedia, path: context.requestedPath)
        } catch {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        }
    }

    func v2MobileTerminalArtifactFetch(params: [String: Any]) async -> V2CallResult {
        let resolution = mobileTerminalArtifactContext(params: params, requiresPath: true)
        guard case .success(let context) = resolution else {
            return resolution.failureResult
        }
        let offset = max(0, Int64(v2Int(params, "offset") ?? 0))
        let length = ChatArtifactTransferPolicy.defaultPolicy
            .clampedChunkLength(v2Int(params, "length"))
        do {
            let chunk = try await Task.detached(priority: .utility) {
                try context.authorizedRead { reader, canonicalPath in
                    try reader.fetch(path: canonicalPath, offset: offset, length: length)
                }
            }.value
            return .ok(TerminalArtifactWire.payload(chunk) ?? [:])
        } catch TerminalArtifactReadContext.Error.forbidden {
            cmuxDebugLog("mobile.terminal.artifact.forbidden op=fetch path=\(context.requestedPath ?? "nil")")
            return mobileTerminalArtifactError(.forbidden, path: context.requestedPath)
        } catch ArtifactByteReader.Error.fileNotFound {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        } catch {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        }
    }

    func v2MobileTerminalArtifactThumbnail(params: [String: Any]) async -> V2CallResult {
        let resolution = mobileTerminalArtifactContext(params: params, requiresPath: true)
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
            return .ok(TerminalArtifactWire.payload(thumbnail) ?? [:])
        } catch TerminalArtifactReadContext.Error.forbidden {
            cmuxDebugLog("mobile.terminal.artifact.forbidden op=thumbnail path=\(context.requestedPath ?? "nil")")
            return mobileTerminalArtifactError(.forbidden, path: context.requestedPath)
        } catch ArtifactByteReader.Error.fileNotFound {
            return mobileTerminalArtifactError(.fileNotFound, path: context.requestedPath)
        } catch {
            return mobileTerminalArtifactError(.unsupportedMedia, path: context.requestedPath)
        }
    }

    private func mobileTerminalArtifactContext(
        params: [String: Any],
        requiresPath: Bool
    ) -> TerminalArtifactContextResolution {
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
            let terminalText = readTerminalTextForSnapshot(
                terminalPanel: terminalPanel,
                includeScrollback: true,
                lineLimit: nil,
                allowVTExport: true
            ) ?? ""
            return .success(TerminalArtifactReadContext(
                terminalText: terminalText,
                workingDirectory: workingDirectory,
                requestedPath: v2RawString(params, "path")
            ))
        }
    }

    private enum MobileTerminalArtifactErrorKind {
        case notFound
        case forbidden
        case fileNotFound
        case unsupportedMedia
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

    private let terminalText: String
    private let workingDirectory: String?
    let requestedPath: String?

    init(
        terminalText: String,
        workingDirectory: String?,
        requestedPath: String?
    ) {
        self.terminalText = terminalText
        self.workingDirectory = workingDirectory
        self.requestedPath = requestedPath
    }

    func scan() -> TerminalArtifactScanResponse {
        let reader = ArtifactByteReader()
        let scope = TerminalArtifactScope(
            terminalText: terminalText,
            workingDirectory: workingDirectory,
            resolver: ChatArtifactScope.FoundationResolver()
        )
        let artifacts = scope.artifactPaths(limit: 200).compactMap { path -> TerminalArtifactReference? in
            guard let stat = try? reader.stat(path: path) else { return nil }
            guard !stat.isDirectory else { return nil }
            return TerminalArtifactReference(
                path: path,
                kind: stat.kind,
                displayName: URL(fileURLWithPath: path).lastPathComponent
            )
        }
        return TerminalArtifactScanResponse(artifacts: artifacts)
    }

    func authorizedRead<T>(
        _ operation: (ArtifactByteReader, String) throws -> T
    ) throws -> T {
        guard let requestedPath else { throw Error.forbidden }
        let scope = TerminalArtifactScope(
            terminalText: terminalText,
            workingDirectory: workingDirectory,
            resolver: ChatArtifactScope.FoundationResolver()
        )
        guard let canonicalPath = scope.canonicalPath(for: requestedPath) else {
            throw Error.forbidden
        }
        return try operation(ArtifactByteReader(), canonicalPath)
    }
}

private struct TerminalArtifactWire {
    static func payload<T: Encodable>(_ value: T) -> [String: Any]? {
        let coding = ChatWireCoding()
        guard let data = try? coding.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
