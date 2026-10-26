import AppKit
import Observation

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

    private let rows = NSHashTable<WorkspaceRowView>.weakObjects()
    private var current: Values?

    /// The current values; `changed()` redraws `row`.
    func values(for row: WorkspaceRowView) -> Values {
        rows.add(row)
        if let current { return current }
        let values = (SidebarTunables.agentMark.value, SidebarTunables.presenceDots.value, SidebarRowBadgeStyle.tunable.value,
                      SidebarRowBadgeStackCap.tunable.value, SidebarTunables.workspaceTitleMotion.value, SidebarTunables.quietUnnamedRows.value)
        current = values
        return values
    }

    /// Forgets the kept values: the next row configured reads them again. The look watch calls it
    /// before it redraws its rows.
    func drop() {
        current = nil
    }

    /// Drops the kept values and redraws every live row now: a test that sets a tunable and draws a
    /// row in the same turn calls it right after the set.
    func changed() {
        drop()
        for row in rows.allObjects { row.redrawLastConfiguration() }
    }
}
