import CMUXMobileCore
import CmuxAgentChat
import CmuxControlSocket
import Foundation

/// Mobile surface inventory and focus support kept outside `TerminalController.swift`.
extension TerminalController {
    /// Maps an app panel kind to the shared, open mobile wire vocabulary.
    func mobileSurfaceKind(for panelType: PanelType) -> MobileSurfaceKind {
        switch panelType {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .customSidebar:
            return .customSidebar
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        case .extensionBrowser:
            return .extensionBrowser
        case .workspaceTodo:
            return .todo
        case .cloudVMLoading:
            return .cloudVMLoading
        }
    }

    /// Builds the stable, spatially ordered mobile descriptors for every panel.
    func mobileSurfaceDescriptors(in workspace: Workspace) -> [WorkspaceSyncRecord.Surface] {
        orderedPanels(in: workspace).map { panel in
            let filePath: String?
            switch panel {
            case let markdown as MarkdownPanel:
                filePath = markdown.filePath
            case let filePreview as FilePreviewPanel:
                filePath = filePreview.filePath
            default:
                filePath = nil
            }
            if let filePath {
                panelArtifactAuthorizationStore.record(
                    workspaceID: workspace.id.uuidString,
                    surfaceID: panel.id.uuidString,
                    filePath: filePath
                )
            } else {
                panelArtifactAuthorizationStore.invalidate(
                    workspaceID: workspace.id.uuidString,
                    surfaceID: panel.id.uuidString
                )
            }
            return WorkspaceSyncRecord.Surface(
                surfaceID: panel.id.uuidString,
                kind: mobileSurfaceKind(for: panel.panelType).rawValue,
                title: workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                filePath: filePath
            )
        }
    }

    /// Focuses a Mac surface through the same mutation witness as `surface.focus`.
    func v2MobileSurfaceFocus(params: [String: Any]) -> V2CallResult {
        guard let workspaceID = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceID = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            paneID: nil
        )
        guard controlSurfaceRoutingResolvesTabManager(routing: routing) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        switch controlSurfaceFocus(routing: routing, surfaceID: surfaceID) {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case let .surfaceNotFound(id):
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: ["surface_id": id.uuidString]
            )
        case let .focused(windowID, focusedWorkspaceID, focusedSurfaceID):
            return .ok([
                "workspace_id": focusedWorkspaceID.uuidString,
                "surface_id": focusedSurfaceID.uuidString,
                "window_id": v2OrNull(windowID?.uuidString),
            ])
        }
    }

    /// Dispatches lifecycle-bound file reads for markdown and file-preview panels.
    func v2MobilePanelArtifactDispatch(
        method: String,
        params: [String: Any],
        executionContext: MobileHostRPCExecutionContext? = nil
    ) async -> V2CallResult {
        switch method {
        case "mobile.panel.artifact.stat":
            return await v2MobilePanelArtifactStat(params: params)
        case "mobile.panel.artifact.fetch":
            return await v2MobilePanelArtifactFetch(
                params: params,
                executionContext: executionContext
            )
        case "mobile.panel.artifact.thumbnail":
            return await v2MobilePanelArtifactThumbnail(params: params)
        default:
            return .err(
                code: "method_not_found",
                message: String(
                    localized: "mobile.panel.artifact.error.methodNotFound",
                    defaultValue: "cmux doesn't recognize that panel file request."
                ),
                data: nil
            )
        }
    }

    func v2MobilePanelArtifactStat(params: [String: Any]) async -> V2CallResult {
        let resolution = mobilePanelArtifactCanonicalPath(params: params)
        guard let canonicalPath = resolution.canonicalPath else {
            return resolution.failure ?? mobilePanelArtifactInternalError()
        }
        do {
            let stat = try await Task.detached(priority: .utility) {
                try ArtifactByteReader().stat(path: canonicalPath)
            }.value
            return mobilePanelArtifactResult(stat)
        } catch ArtifactByteReader.Error.fileNotFound {
            return mobilePanelArtifactFileError(
                code: "file_not_found",
                key: "mobile.chat.artifact.error.fileNotFound",
                defaultValue: "That file is no longer available on the Mac.",
                path: v2RawString(params, "path")
            )
        } catch ArtifactByteReader.Error.unsupportedMedia {
            return mobilePanelArtifactFileError(
                code: "unsupported_media",
                key: "mobile.chat.artifact.error.unsupportedMedia",
                defaultValue: "This file type cannot be previewed.",
                path: v2RawString(params, "path")
            )
        } catch {
            return mobilePanelArtifactFileError(
                code: "file_not_found",
                key: "mobile.chat.artifact.error.fileNotFound",
                defaultValue: "That file is no longer available on the Mac.",
                path: v2RawString(params, "path")
            )
        }
    }

    func v2MobilePanelArtifactFetch(
        params: [String: Any],
        executionContext: MobileHostRPCExecutionContext? = nil
    ) async -> V2CallResult {
        let resolution = mobilePanelArtifactCanonicalPath(params: params)
        guard let canonicalPath = resolution.canonicalPath else {
            return resolution.failure ?? mobilePanelArtifactInternalError()
        }
        let offset = max(0, Int64(v2Int(params, "offset") ?? 0))
        let length = ChatArtifactTransferPolicy.defaultPolicy
            .clampedChunkLength(v2Int(params, "length"))
        do {
            if v2RawString(params, "transport") == "iroh_artifact_v1" {
                guard let executionContext else {
                    return mobilePanelArtifactFileError(
                        code: "unsupported_transport",
                        key: "mobile.chat.artifact.error.irohTransportUnavailable",
                        defaultValue: "Artifact transfer requires an authenticated session.",
                        path: nil
                    )
                }
                return mobilePanelArtifactResult(
                    try await executionContext.issueArtifactTransfer(
                        canonicalPath: canonicalPath
                    )
                )
            }
            let chunk = try await Task.detached(priority: .utility) {
                try ArtifactByteReader().fetch(
                    path: canonicalPath,
                    offset: offset,
                    length: length
                )
            }.value
            return mobilePanelArtifactResult(chunk)
        } catch let error as MobileHostIrohArtifactTransferRegistry.Error {
            switch error.issueFailure {
            case .fileNotFound:
                return mobilePanelArtifactFileError(
                    code: "file_not_found",
                    key: "mobile.chat.artifact.error.fileNotFound",
                    defaultValue: "That file is no longer available on the Mac.",
                    path: v2RawString(params, "path")
                )
            case .unavailable:
                return mobilePanelArtifactFileError(
                    code: "unavailable",
                    key: "mobile.chat.artifact.error.transferUnavailable",
                    defaultValue: "Artifact transfer is temporarily unavailable.",
                    path: nil
                )
            }
        } catch ArtifactByteReader.Error.fileNotFound {
            return mobilePanelArtifactFileError(
                code: "file_not_found",
                key: "mobile.chat.artifact.error.fileNotFound",
                defaultValue: "That file is no longer available on the Mac.",
                path: v2RawString(params, "path")
            )
        } catch {
            return mobilePanelArtifactFileError(
                code: "file_not_found",
                key: "mobile.chat.artifact.error.fileNotFound",
                defaultValue: "That file is no longer available on the Mac.",
                path: v2RawString(params, "path")
            )
        }
    }

    func v2MobilePanelArtifactThumbnail(params: [String: Any]) async -> V2CallResult {
        let resolution = mobilePanelArtifactCanonicalPath(params: params)
        guard let canonicalPath = resolution.canonicalPath else {
            return resolution.failure ?? mobilePanelArtifactInternalError()
        }
        let maxDimension = min(max(v2Int(params, "max_dimension") ?? 512, 64), 1024)
        do {
            let thumbnail = try await Task.detached(priority: .utility) {
                try ArtifactByteReader().thumbnail(
                    path: canonicalPath,
                    maxDimension: maxDimension
                )
            }.value
            return mobilePanelArtifactResult(thumbnail)
        } catch ArtifactByteReader.Error.fileNotFound {
            return mobilePanelArtifactFileError(
                code: "file_not_found",
                key: "mobile.chat.artifact.error.fileNotFound",
                defaultValue: "That file is no longer available on the Mac.",
                path: v2RawString(params, "path")
            )
        } catch {
            return mobilePanelArtifactFileError(
                code: "unsupported_media",
                key: "mobile.chat.artifact.error.unsupportedMedia",
                defaultValue: "This file type cannot be previewed.",
                path: v2RawString(params, "path")
            )
        }
    }

    private func mobilePanelArtifactCanonicalPath(
        params: [String: Any]
    ) -> (canonicalPath: String?, failure: V2CallResult?) {
        guard let requestedWorkspaceID = v2UUID(params, "workspace_id"),
              let requestedSurfaceID = v2UUID(params, "surface_id"),
              let requestedPath = mobileNonEmpty(v2RawString(params, "path")) else {
            return (nil, .err(
                code: "invalid_params",
                message: String(
                    localized: "mobile.panel.artifact.error.invalidParams",
                    defaultValue: "cmux couldn't tell which panel or file was requested."
                ),
                data: nil
            ))
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(
            params: params,
            requireTerminal: false
        ), let resolvedSurfaceID = resolved.surfaceId,
           resolved.workspace.id == requestedWorkspaceID,
           resolvedSurfaceID == requestedSurfaceID,
           let panel = resolved.workspace.panels[resolvedSurfaceID] else {
            return (nil, .err(
                code: "not_found",
                message: String(
                    localized: "mobile.panel.artifact.error.panelNotFound",
                    defaultValue: "That file panel is no longer available."
                ),
                data: nil
            ))
        }

        let currentFilePath: String?
        switch panel {
        case let markdown as MarkdownPanel:
            currentFilePath = markdown.filePath
        case let filePreview as FilePreviewPanel:
            currentFilePath = filePreview.filePath
        default:
            currentFilePath = nil
        }
        guard let currentFilePath else {
            panelArtifactAuthorizationStore.invalidate(
                workspaceID: requestedWorkspaceID.uuidString,
                surfaceID: requestedSurfaceID.uuidString
            )
            return (nil, .err(
                code: "not_found",
                message: String(
                    localized: "mobile.panel.artifact.error.panelNotFound",
                    defaultValue: "That file panel is no longer available."
                ),
                data: nil
            ))
        }

        // Refresh from the live panel immediately before authorization. This is
        // what makes a symlink retarget or same-surface file replacement revoke
        // the previous canonical path even before the next inventory emission.
        panelArtifactAuthorizationStore.record(
            workspaceID: requestedWorkspaceID.uuidString,
            surfaceID: requestedSurfaceID.uuidString,
            filePath: currentFilePath
        )
        guard let canonicalPath = panelArtifactAuthorizationStore.authorizedCanonicalPath(
            workspaceID: requestedWorkspaceID.uuidString,
            surfaceID: requestedSurfaceID.uuidString,
            requestedPath: requestedPath
        ) else {
            return (nil, .err(
                code: "forbidden",
                message: String(
                    localized: "mobile.panel.artifact.error.forbidden",
                    defaultValue: "That file is not currently shown in this panel."
                ),
                data: ["path": requestedPath]
            ))
        }
        return (canonicalPath, nil)
    }

    private func mobilePanelArtifactResult<T: Encodable>(_ value: T) -> V2CallResult {
        let coding = ChatWireCoding()
        guard let data = try? coding.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return mobilePanelArtifactInternalError()
        }
        return .ok(object)
    }

    private func mobilePanelArtifactFileError(
        code: String,
        key: String.LocalizationValue,
        defaultValue: String.LocalizationValue,
        path: String?
    ) -> V2CallResult {
        .err(
            code: code,
            message: String(localized: key, defaultValue: defaultValue),
            data: path.map { ["path": $0] }
        )
    }

    private func mobilePanelArtifactInternalError() -> V2CallResult {
        .err(
            code: "internal_error",
            message: String(
                localized: "mobile.panel.artifact.error.internal",
                defaultValue: "cmux couldn't complete the panel file request."
            ),
            data: nil
        )
    }
}
