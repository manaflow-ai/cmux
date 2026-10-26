public import CmuxNextDesignTokens

/// The workspace auto-name variants (hq#1957; Debug Settings
/// `workspaces.autoName.variant`, DEV and NIGHTLY only). Persisted first-chat
/// titles are the default; live labels remain available for comparison.
public nonisolated enum WorkspaceAutoNameVariant: String, Sendable, CaseIterable, TunableChoice {
    /// The sidebar row shows the name its front tab gives, and follows that tab
    /// as it changes; the daemon keeps the default name.
    case live
    /// The first generated chat title is written to the daemon once, so the
    /// CLI, window title and search see it. Manual and agent renames win.
    case persist

    public var tunableTitle: String {
        switch self {
        case .live: "A: Live label (sidebar only, follows the front tab)"
        case .persist: "B: Rename once (daemon name, CLI and search see it)"
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
