import CMUXMobileCore
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
            return WorkspaceSyncRecord.Surface(
                surfaceID: panel.id.uuidString,
                kind: mobileSurfaceKind(for: panel.panelType).rawValue,
                title: workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                filePath: filePath,
                todo: panel.panelType == .workspaceTodo ? mobileTodoSnapshot(in: workspace) : nil
            )
        }
    }

    /// Projects the workspace-owned todo model without carrying Mac-local attachments.
    func mobileTodoSnapshot(in workspace: Workspace) -> MobileTodoSnapshot {
        let status: MobileTodoStatus = switch workspace.effectiveTaskStatus {
        case .todo: .todo
        case .working: .working
        case .needsAttention: .needsAttention
        case .review: .review
        case .done: .done
        }
        return MobileTodoSnapshot(
            status: status,
            statusHidden: workspace.todoState.statusHidden,
            items: workspace.todoState.checklist.map { item in
                let state: MobileTodoItemState = switch item.state {
                case .pending: .pending
                case .inProgress: .inProgress
                case .completed: .completed
                }
                let origin: MobileTodoItemOrigin = switch item.origin {
                case .user: .user
                case .agent: .agent
                }
                return MobileTodoItem(
                    id: item.id.uuidString,
                    text: item.text,
                    state: state,
                    origin: origin
                )
            }
        )
    }

    /// Bridges a typed todo snapshot into the legacy workspace-list JSON shape.
    func mobileTodoPayload(_ todo: MobileTodoSnapshot) -> [String: Any] {
        [
            "status": todo.status.rawValue,
            "status_hidden": todo.statusHidden,
            "items": todo.items.map { item in
                [
                    "id": item.id,
                    "text": item.text,
                    "state": item.state.rawValue,
                    "origin": item.origin.rawValue,
                ]
            },
        ]
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
}
