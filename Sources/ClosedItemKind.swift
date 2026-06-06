/// Coarse category of a closed item, used to pick a row icon in the History pane.
enum ClosedItemKind: String, Equatable, Hashable, Sendable {
    case terminal
    case browser
    case markdown
    case filePreview
    case project
    case tool
    case history
    case extensionBrowser
    case workspace
    case window

    /// SF Symbol name representing this kind in the History pane.
    var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .markdown: return "doc.richtext"
        case .filePreview: return "doc"
        case .project: return "folder"
        case .tool: return "wrench.and.screwdriver"
        case .history: return "clock.arrow.circlepath"
        case .extensionBrowser: return "puzzlepiece.extension"
        case .workspace: return "rectangle.stack"
        case .window: return "macwindow"
        }
    }

    /// Maps a closed panel's `PanelType` to its closed-item kind.
    static func forPanel(_ type: PanelType) -> ClosedItemKind {
        switch type {
        case .terminal: return .terminal
        case .browser: return .browser
        case .markdown: return .markdown
        case .filePreview: return .filePreview
        case .rightSidebarTool: return .tool
        case .project: return .project
        case .history: return .history
        case .extensionBrowser: return .extensionBrowser
        }
    }
}
