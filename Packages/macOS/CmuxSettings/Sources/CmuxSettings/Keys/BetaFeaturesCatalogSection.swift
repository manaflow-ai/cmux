import Foundation

/// Beta-feature toggles. Each key here gates an experimental code path
/// in the running app. New beta keys should follow the pattern
/// `<feature-domain>.beta.<flag-name>` so the cmux.json view groups them
/// sensibly.
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

    /// Conversations: opt-in unified coding-agent session navigation in the
    /// left sidebar. Disabling it hides the provider while preserving sessions.
    public let conversationSidebar = DefaultsKey<Bool>(
        id: "sidebar.beta.conversations.enabled",
        defaultValue: false,
        userDefaultsKey: "sidebar.beta.conversations.enabled"
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

    /// Cloud Machines' persisted first-use activation marker. The row moved out
    /// of Beta Features when Cloud graduated; this storage key remains stable
    /// so installed users keep their activation and existing configuration
    /// domains migrate without a destructive reset.
    public let cloudMachines = DefaultsKey<Bool>(
        id: "cloud.beta.machines.enabled",
        defaultValue: Self.cloudMachinesDefault,
        userDefaultsKey: "cloud.beta.machines.enabled"
    )

    private static let cloudMachinesDefault = false

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

    /// Remote host origin colors: tint each remote workspace's sidebar row and
    /// tab with a stable per-host color (hashed from the host name into a palette
    /// picked to stay distinguishable, collisions taking the next color) so servers are easy
    /// to tell apart and a given host shows the same color in every window. A
    /// user's manual workspace color always wins. Defaults off; while off, remote
    /// workspaces render with no origin tint.
    public let remoteTmuxOriginColors = DefaultsKey<Bool>(
        id: "remoteTmux.beta.originColors.enabled",
        defaultValue: false,
        userDefaultsKey: "remoteTmux.beta.originColors.enabled"
    )

    /// Remote host names on duplicate titles: when sidebar workspaces share a title and come from
    /// different places, show each remote one's host after its title, leaving off the domain the
    /// hosts share. Defaults off; while off, titles show as they are.
    public let remoteTmuxOriginHostTitles = DefaultsKey<Bool>(
        id: "remoteTmux.beta.originHostTitles.enabled",
        defaultValue: false,
        userDefaultsKey: "remoteTmux.beta.originHostTitles.enabled"
    )

    public init() {}
}
