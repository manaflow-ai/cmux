public import CmuxNextDesignTokens

/// The workspace auto-name variants (hq#1957; Debug Settings
/// `workspaces.autoName.variant`, DEV and NIGHTLY only). Following the focused
/// chat in the daemon is the default; live labels remain available for comparison.
public nonisolated enum WorkspaceAutoNameVariant: String, Sendable, CaseIterable, TunableChoice {
    /// The sidebar row shows the name its front tab gives, and follows that tab
    /// as it changes; the daemon keeps the default name.
    case live
    /// The focused chat's generated title is written to the daemon, so the
    /// CLI, window title and search follow it. Manual and agent renames win.
    case persist

    public var tunableTitle: String {
        switch self {
        case .live: "A: Live label (sidebar only, follows the front tab)"
        case .persist: "B: Follow focused chat (daemon name, CLI and search see it)"
        }
    }
}

/// Debug Settings declarations of workspace auto-naming (DEV and NIGHTLY).
public nonisolated struct WorkspaceAutoNameTunables {
    public nonisolated init() {}

    public static let variant = Tunable<WorkspaceAutoNameVariant>.choice(
        "workspaces.autoName.variant", .sidebar, "Workspace auto-name",
        help: "How a workspace you never named takes its front tab's name. Applies at once.",
        default: .persist, code: "WorkspaceAutoNameTunables.variant")

    public static var all: [TunableDescriptor] { [variant.descriptor] }
}
