public import CmuxPanes

public extension PanelType {
    /// The command-palette surface keyword kind for this panel type.
    ///
    /// An identity-shaped 1:1 mapping onto ``CommandPaletteSurfaceKeywordKind``:
    /// each panel type yields the same-named keyword kind, which drives the
    /// switcher's static keyword vocabulary. The localized kind *labels* stay
    /// host-side (they resolve against the app bundle), so this property carries
    /// only the keyword-kind selection. The exhaustive switch keeps the mapping
    /// honest if either enum gains a case.
    var commandPaletteSurfaceKeywordKind: CommandPaletteSurfaceKeywordKind {
        switch self {
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
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        case .extensionBrowser:
            return .extensionBrowser
        }
    }
}
