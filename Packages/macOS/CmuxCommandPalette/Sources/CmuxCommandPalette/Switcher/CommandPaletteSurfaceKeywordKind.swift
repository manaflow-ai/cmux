import Foundation

/// The surface kinds the switcher recognizes, mirroring the host's panel-type
/// enum so the package can derive a surface's static search keywords without
/// importing the app-target panel type.
///
/// The host adapter maps each live panel type onto one of these cases when it
/// builds a ``CommandPaletteSwitcherSnapshotSurface``; the builder reads the
/// case to produce the kind's keyword list. Localized kind *labels* stay
/// host-side (they resolve against the app bundle), so this enum carries only
/// the stable keyword vocabulary.
public enum CommandPaletteSurfaceKeywordKind: Sendable {
    /// A terminal surface.
    case terminal
    /// A browser surface.
    case browser
    /// A markdown surface.
    case markdown
    /// A file-preview surface.
    case filePreview
    /// A right-sidebar tool surface.
    case rightSidebarTool
    /// An agent-session surface.
    case agentSession
    /// A project surface.
    case project
    /// A sidebar-extension browser surface.
    case extensionBrowser
    /// A Cloud VM loading surface.
    case cloudVMLoading

    /// The static search keywords for this surface kind.
    public var keywords: [String] {
        switch self {
        case .terminal:
            return ["terminal", "shell", "console"]
        case .browser:
            return ["browser", "web", "page"]
        case .markdown:
            return ["markdown", "note", "preview"]
        case .filePreview:
            return ["file", "preview", "text", "pdf", "image", "audio", "video"]
        case .rightSidebarTool:
            return ["tool", "files", "find", "vault", "sidebar"]
        case .agentSession:
            return ["agent", "codex", "claude", "opencode", "react", "solid"]
        case .project:
            return ["project", "xcode", "build", "settings", "schemes", "targets"]
        case .extensionBrowser:
            return ["sidebar", "extensions", "extensionkit", "browser"]
        case .cloudVMLoading:
            return ["cloud", "vm", "remote", "loading"]
        }
    }
}
