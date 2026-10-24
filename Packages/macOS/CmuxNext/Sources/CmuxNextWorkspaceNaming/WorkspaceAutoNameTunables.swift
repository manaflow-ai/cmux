public import CmuxNextDesignTokens

/// The workspace auto-name prototypes (hq#1957; Debug Settings
/// `workspaces.autoName.variant`, DEV and NIGHTLY only; Release always uses
/// `live`). One is deleted once Leo picks after dogfood.
public nonisolated enum WorkspaceAutoNameVariant: String, Sendable, CaseIterable, TunableChoice {
    /// A: the sidebar row shows the name its front tab gives, and follows that
    /// tab as it changes; the daemon keeps the default name.
    case live
    /// B: as `live`, and the first name the front tab gives is written to the
    /// daemon once (Rename Workspace's command), so the CLI, window title and
    /// search see it.
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
        default: .live, code: "WorkspaceAutoNameTunables.variant")

    public static var all: [TunableDescriptor] { [variant.descriptor] }
}
