public import CmuxCore

/// The persisted counterpart of `CmuxCore.SidebarSelection` inside a session
/// snapshot.
///
/// A pure leaf value mirroring which top-level pane the sidebar showed (`tabs`
/// or `notifications`), encoded as a stable raw string so the on-disk wire
/// format stays independent of the in-memory `SidebarSelection`. The on-disk
/// format is owned by the app's `SessionSidebarSnapshot`; encoding stays
/// byte-identical to the legacy app-target definition. Bridges to/from
/// `SidebarSelection` via `init(selection:)` and `sidebarSelection`.
public enum SessionSidebarSelection: String, Codable, Sendable, Equatable {
    /// The vertical workspace tabs list.
    case tabs
    /// The notifications list.
    case notifications

    /// Creates the persisted selection mirroring an in-memory `SidebarSelection`.
    public init(selection: SidebarSelection) {
        switch selection {
        case .tabs:
            self = .tabs
        case .notifications:
            self = .notifications
        }
    }

    /// The in-memory `SidebarSelection` this persisted value restores to.
    public var sidebarSelection: SidebarSelection {
        switch self {
        case .tabs:
            return .tabs
        case .notifications:
            return .notifications
        }
    }
}
