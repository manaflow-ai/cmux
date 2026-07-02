import Foundation

/// Beta-feature toggles. Each key here gates an experimental code path
/// in the running app. The id prefix is `rightSidebar.beta.*` for the
/// existing right-sidebar Dock toggle; new betas should follow the
/// pattern `<feature-domain>.beta.<flag-name>` so the cmux.json view
/// groups them sensibly.
public struct BetaFeaturesCatalogSection: SettingCatalogSection {
    /// Right-sidebar Feed: an experimental mode that surfaces inline agent
    /// decisions (permission prompts, questions) in the right-sidebar mode
    /// switcher. Defaults off; while off, the Feed mode is hidden from the
    /// switcher so the feature stays opt-in while it is in beta.
    public let rightSidebarFeed = DefaultsKey<Bool>(
        id: "rightSidebar.beta.feed.enabled",
        defaultValue: false,
        userDefaultsKey: "rightSidebar.beta.feed.enabled"
    )

    /// Right-sidebar Dock: an experimental terminal-controls dock that
    /// replaces the per-pane action chrome with a unified right-side
    /// rail. Defaults off; flagged as unstable in the Settings UI.
    public let rightSidebarDock = DefaultsKey<Bool>(
        id: "rightSidebar.beta.dock.enabled",
        defaultValue: false,
        userDefaultsKey: "rightSidebar.beta.dock.enabled"
    )

    /// Extensions: the experimental ExtensionKit sidebar-extension surface
    /// (puzzle button, sidebar-toggle provider menu, installed-extension
    /// host, and the extensions browser). Defaults off; while off, every
    /// extension-related entry point is hidden so the feature stays opt-in
    /// while it is in beta.
    public let extensions = DefaultsKey<Bool>(
        id: "extensions.beta.enabled",
        defaultValue: false,
        userDefaultsKey: "extensions.beta.enabled"
    )

    /// Custom sidebars: user/agent-authored sidebars (interpreted Swift or
    /// JSON) discovered from `~/.config/cmux/sidebars/` and selectable in the
    /// sidebar button's provider picker. Defaults on; while off, no custom
    /// sidebar appears in the picker and a persisted custom selection falls
    /// back to the default workspaces sidebar.
    public let customSidebars = DefaultsKey<Bool>(
        id: "customSidebars.beta.enabled",
        defaultValue: true,
        userDefaultsKey: "customSidebars.beta.enabled"
    )

    /// Workspace todos: the per-workspace task-status glyph, checklist, and
    /// todo pane. Off by default; the first successful status/checklist
    /// mutation from any entrypoint (context menu, palette, socket, CLI)
    /// flips it on. The UserDefaults key predates the move into the beta
    /// catalog, so stored round-1 values keep working.
    public let workspaceTodos = DefaultsKey<Bool>(
        id: "sidebar.beta.workspaceTodos.enabled",
        defaultValue: false,
        userDefaultsKey: "sidebarWorkspaceTodos"
    )

    /// How a workspace row's checklist opens from its summary line while the
    /// workspace-todos beta is on: an anchored popover (default) or the
    /// round-1 inline expansion.
    public let workspaceTodosChecklistStyle = DefaultsKey<WorkspaceTodoChecklistStyle>(
        id: "sidebar.beta.workspaceTodos.checklistStyle",
        defaultValue: .popover,
        userDefaultsKey: "sidebarWorkspaceTodosChecklistStyle"
    )

    /// Remote tmux: mirror a remote host's tmux sessions in the cmux sidebar
    /// over `ssh … tmux -CC` (iTerm2-style control mode). Sessions appear as
    /// sidebar workspaces, tmux windows as tabs, and tmux panes as splits;
    /// create/close propagate to the remote, while quitting cmux leaves the
    /// remote tmux server running for resume. Defaults off; while off, every
    /// remote-tmux entry point and socket command is gated out so the local
    /// terminal path is unaffected.
    public let remoteTmux = DefaultsKey<Bool>(
        id: "remoteTmux.beta.enabled",
        defaultValue: false,
        userDefaultsKey: "remoteTmux.beta.enabled"
    )

    public init() {}
}
