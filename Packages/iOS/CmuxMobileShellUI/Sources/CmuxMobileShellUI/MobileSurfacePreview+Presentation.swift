import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

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

    /// Accent used for the kind glyph in badges, cards, and picker rows.
    var tint: Color {
        switch self {
        case .terminal: .green
        case .todo: .blue
        case .markdown: .indigo
        case .filePreview: .teal
        case .browser: .blue
        case .agentSession: .purple
        case .project: .orange
        case .customSidebar: .cyan
        case .rightSidebarTool: .gray
        case .extensionBrowser: .pink
        case .cloudVMLoading: .cyan
        case .other: .gray
        }
    }

    /// One-line card copy explaining where this surface actually lives.
    var fallbackExplainer: String {
        switch self {
        case .browser:
            L10n.string(
                "mobile.surface.explainer.browser",
                defaultValue: "This browser tab is open in cmux on your Mac."
            )
        case .agentSession:
            L10n.string(
                "mobile.surface.explainer.agentSession",
                defaultValue: "This agent session is running in cmux on your Mac."
            )
        case .project:
            L10n.string(
                "mobile.surface.explainer.project",
                defaultValue: "This pane browses the project's files on your Mac."
            )
        case .customSidebar:
            L10n.string(
                "mobile.surface.explainer.customSidebar",
                defaultValue: "This panel is drawn by a sidebar extension on your Mac."
            )
        case .rightSidebarTool:
            L10n.string(
                "mobile.surface.explainer.rightSidebarTool",
                defaultValue: "This tool lives in the right sidebar on your Mac."
            )
        case .extensionBrowser:
            L10n.string(
                "mobile.surface.explainer.extensionBrowser",
                defaultValue: "This extension view opens in cmux on your Mac."
            )
        case .cloudVMLoading:
            L10n.string(
                "mobile.surface.explainer.cloudVM",
                defaultValue: "This Cloud VM is still starting up on your Mac."
            )
        case .other:
            L10n.string(
                "mobile.surface.explainer.other",
                defaultValue: "This surface needs a newer version of the iOS app."
            )
        case .terminal, .todo, .markdown, .filePreview:
            L10n.string(
                "mobile.surface.explainer.generic",
                defaultValue: "This view is rendered by cmux on your Mac."
            )
        }
    }
}
