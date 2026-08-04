import CmuxMobileShellModel
import CmuxMobileSupport

extension MobileSurfacePreview.Kind {
    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .todo: "checklist"
        case .markdown: "doc.richtext"
        case .filePreview: "doc.text.magnifyingglass"
        case .browser: "globe"
        case .agentSession: "bubble.left.and.text.bubble.right"
        case .project: "hammer"
        case .customSidebar: "sidebar.right"
        case .rightSidebarTool: "wrench.and.screwdriver"
        case .extensionBrowser: "puzzlepiece.extension"
        case .cloudVMLoading: "icloud"
        case .other: "rectangle.dashed"
        }
    }

    var displayName: String {
        switch self {
        case .terminal: L10n.string("mobile.surface.kind.terminal", defaultValue: "Terminal")
        case .browser: L10n.string("mobile.surface.kind.browser", defaultValue: "Browser")
        case .markdown: L10n.string("mobile.surface.kind.markdown", defaultValue: "Markdown")
        case .filePreview: L10n.string("mobile.surface.kind.filePreview", defaultValue: "File Preview")
        case .rightSidebarTool: L10n.string("mobile.surface.kind.rightSidebarTool", defaultValue: "Sidebar Tool")
        case .customSidebar: L10n.string("mobile.surface.kind.customSidebar", defaultValue: "Custom Sidebar")
        case .agentSession: L10n.string("mobile.surface.kind.agentSession", defaultValue: "Agent Session")
        case .project: L10n.string("mobile.surface.kind.project", defaultValue: "Project")
        case .extensionBrowser: L10n.string("mobile.surface.kind.extensionBrowser", defaultValue: "Extension Browser")
        case .todo: L10n.string("mobile.surface.kind.todo", defaultValue: "Todo")
        case .cloudVMLoading: L10n.string("mobile.surface.kind.cloudVM", defaultValue: "Cloud VM")
        case .other: L10n.string("mobile.surface.kind.other", defaultValue: "Other Surface")
        }
    }
}
