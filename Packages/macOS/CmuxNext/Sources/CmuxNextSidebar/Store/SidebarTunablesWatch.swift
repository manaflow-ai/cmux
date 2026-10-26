import AppKit

/// The sidebar tunables workspace rows draw from (agent mark, presence dots,
/// row badge, stack size, quiet unnamed rows), read once for every row. Each
/// `WorkspaceRowView.configure` used to arm its own observation, so every
/// status tick left one more registration behind; now the values are read once
/// and kept until the sidebar's look watch (`SidebarLookWatch`) drops them and
/// redraws its rows.
@MainActor
final class SidebarTunablesWatch {
    static let shared = SidebarTunablesWatch()

    typealias Values = (agentMark: SidebarAgentMarkVariant, presenceDots: Bool, rowBadge: SidebarRowBadgeStyle, stackCap: SidebarRowBadgeStackCap, workspaceTitleMotion: SidebarWorkspaceTitleMotionVariant, quietUnnamedRows: Bool)

    private var current: Values?

    /// The current values, read once and kept until ``drop()``.
    func values() -> Values {
        if let current { return current }
        let values = (SidebarTunables.agentMark.value, SidebarTunables.presenceDots.value, SidebarRowBadgeStyle.tunable.value,
                      SidebarRowBadgeStackCap.tunable.value, SidebarTunables.workspaceTitleMotion.value, SidebarTunables.quietUnnamedRows.value)
        current = values
        return values
    }

    /// Forgets the kept values: the next row configured reads them again. The look watch calls it
    /// before it redraws its rows; a test that sets a tunable and draws a row in the same turn calls
    /// it right after the set.
    func drop() {
        current = nil
    }
}
