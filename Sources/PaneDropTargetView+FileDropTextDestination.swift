import Foundation

extension PaneDropTargetView {
    func fileDropTextDestinationKind(
        context: PaneDropContext,
        workspace: Workspace
    ) -> FileDropTextDestinationKind? {
        if hostedView != nil { return .terminal }
        guard let tabId = workspace.bonsplitController.selectedTab(inPane: context.paneId)?.id,
              let panelId = workspace.panelIdFromSurfaceId(tabId),
              let panel = workspace.panels[panelId] else { return nil }

        switch panel.panelType {
        case .terminal:
            return .terminal
        case .filePreview:
            guard let filePreviewPanel = panel as? FilePreviewPanel,
                  filePreviewPanel.previewMode == .text else { return nil }
            return .editor
        case .browser, .markdown, .rightSidebarTool, .customSidebar, .simulator,
             .agentSession, .project, .extensionBrowser, .workspaceTodo, .cloudVMLoading:
            return nil
        }
    }
}
