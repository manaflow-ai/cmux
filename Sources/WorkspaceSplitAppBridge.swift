import Foundation

struct WorkspaceLayoutRenderContext {
    let notificationStore: TerminalNotificationStore?
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let isMinimalMode: Bool
    let appearance: PanelAppearance
    let workspacePortalPriority: Int
    let usesWorkspacePaneOverlay: Bool
    let showSplitButtons: Bool

    func panelVisibleInUI(isSelectedInPane: Bool, isFocused: Bool) -> Bool {
        guard isWorkspaceVisible else { return false }
        return isSelectedInPane || isFocused
    }

    func panelPresentationFacts(
        paneId: PaneID,
        panelId: UUID,
        isSelectedInPane: Bool,
        isFocused: Bool
    ) -> WorkspacePanelPresentationFacts {
        WorkspacePanelPresentationFacts(
            paneId: paneId,
            panelId: panelId,
            isWorkspaceVisible: isWorkspaceVisible,
            isWorkspaceInputActive: isWorkspaceInputActive,
            isSelectedInPane: isSelectedInPane,
            isFocused: isFocused
        )
    }
}

extension WorkspaceLayoutTabKind {
    init?(_ panelType: PanelType?) {
        guard let panelType else { return nil }
        switch panelType {
        case .terminal:
            self = .terminal
        case .browser:
            self = .browser
        case .markdown:
            self = .markdown
        }
    }

    var panelType: PanelType {
        switch self {
        case .terminal:
            .terminal
        case .browser:
            .browser
        case .markdown:
            .markdown
        }
    }
}

extension WorkspaceTerminalPaneAppearance {
    init(_ appearance: PanelAppearance) {
        self.init(
            unfocusedOverlayNSColor: appearance.unfocusedOverlayNSColor,
            unfocusedOverlayOpacity: appearance.unfocusedOverlayOpacity
        )
    }
}

extension WorkspaceSurfaceLifecycleFacts {
    init(_ facts: TerminalViewportLifecycleFacts) {
        self.init(
            isVisibleInUI: facts.isVisibleInUI,
            isWindowed: facts.isWindowed,
            hasUsableGeometry: facts.hasUsableGeometry,
            hasRuntime: facts.hasRuntime,
            hasPresentedFrame: facts.hasPresentedFrame
        )
    }
}

extension WorkspaceSurfacePresentationFacts {
    static func terminal(_ facts: TerminalViewportLifecycleFacts) -> WorkspaceSurfacePresentationFacts {
        terminal(WorkspaceSurfaceLifecycleFacts(facts))
    }
}
