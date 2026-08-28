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

    /// Workspace todo controls: the experimental UI that lets users add
    /// checklist items and set workspace completion/status lanes. Defaults off
    /// so the todo summary remains read-only unless the user opts in or the
    /// remote rollout flag enables it.
    public let workspaceTodoControls = DefaultsKey<Bool>(
        id: "sidebar.beta.workspaceTodos.controls.enabled",
        defaultValue: false,
        userDefaultsKey: "sidebar.beta.workspaceTodos.controls.enabled"
    )

    /// How a workspace row's checklist opens from its summary line while the
    /// workspace-todos feature is on: an anchored popover (default) or the
    /// round-1 inline expansion.
    public let workspaceTodosChecklistStyle = DefaultsKey<WorkspaceTodoChecklistStyle>(
        id: "sidebar.beta.workspaceTodos.checklistStyle",
        defaultValue: .popover,
        userDefaultsKey: "sidebarWorkspaceTodosChecklistStyle"
    )

    /// Cloud Machines: the Cloud tab in the right sidebar plus every other
    /// Cloud VM surface (Settings section, palette commands, titlebar button,
    /// new-workspace menu). Defaults off; the remote rollout flag can also
    /// enable the same surfaces, so this opt-in only ever adds availability.
    public let cloudMachines = DefaultsKey<Bool>(
        id: "cloud.beta.machines.enabled",
        defaultValue: false,
        userDefaultsKey: "cloud.beta.machines.enabled"
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

    /// cmux-tui terminal backend (tier-A spike): back each new main-grid
    /// terminal with a cmux-tui daemon terminal and run
    /// `cmux-tui attach --terminal <id>` as the Ghostty surface command, so
    /// the shell survives quitting the app. Defaults off; while off, terminal
    /// creation and session restore are byte-for-byte today's local spawn
    /// path. This is a throwaway bridge (the shipped data path is the native
    /// CMTH renderer); expect it to be deleted, not extended.
    public let tuiTerminalBackend = DefaultsKey<Bool>(
        id: "terminal.beta.tuiBackend.enabled",
        defaultValue: false,
        userDefaultsKey: "terminal.beta.tuiBackend.enabled"
    )

    /// Path to the cmux-tui binary used by the `tuiTerminalBackend` spike.
    /// Dev-only setting with a spike-only default pointing at a locally
    /// installed npm binary; there is no bundled artifact yet (that is build
    /// item 1 in the migration plan).
    public let tuiTerminalBackendBinaryPath = DefaultsKey<String>(
        id: "terminal.beta.tuiBackend.binaryPath",
        defaultValue: "/Users/lawrence/.local/bin/cmux-tui-npm",
        userDefaultsKey: "terminal.beta.tuiBackend.binaryPath"
    )

    public init() {}
}
