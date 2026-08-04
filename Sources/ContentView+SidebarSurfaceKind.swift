import CmuxExtensionKit

extension CmuxSidebarSurfaceKind {
    init(panelType: PanelType) {
        switch panelType {
        case .terminal:
            self = .terminal
        case .browser:
            self = .browser
        case .application:
            self = .application
        case .markdown:
            self = .markdown
        case .filePreview:
            self = .filePreview
        case .rightSidebarTool:
            self = .rightSidebarTool
        case .customSidebar, .simulator, .extensionBrowser, .workspaceTodo, .cloudVMLoading,
             .mobilePairing, .accountSignIn:
            self = .unknown
        case .agentSession:
            self = .agentSession
        case .project:
            self = .project
        }
    }
}

extension VerticalTabsSidebar {
    func cmuxSidebarSurfaceKind(for panelType: PanelType) -> CmuxSidebarSurfaceKind {
        CmuxSidebarSurfaceKind(panelType: panelType)
    }
}
