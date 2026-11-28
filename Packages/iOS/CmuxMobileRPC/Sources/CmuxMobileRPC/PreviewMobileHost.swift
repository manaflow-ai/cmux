public import CmuxMobileShellModel

/// Static preview fixtures used for SwiftUI previews and disconnected fallback.
public struct PreviewMobileHost {
    private init() {}

    /// The placeholder host name shown when previewing.
    public static let hostName = "cmux-macbook"

    /// A small set of preview workspaces with terminals.
    public static let workspaces: [MobileWorkspacePreview] = [
        MobileWorkspacePreview(
            id: "workspace-main",
            name: "cmux",
            terminals: [
                MobileTerminalPreview(id: "terminal-build", name: "Build"),
                MobileTerminalPreview(id: "terminal-agent", name: "Agent"),
                MobileTerminalPreview(id: "terminal-tui", name: "TUI"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-docs",
            name: "Docs",
            terminals: [
                MobileTerminalPreview(id: "terminal-notes", name: "Notes"),
            ]
        ),
    ]
}
