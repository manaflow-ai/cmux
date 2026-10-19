import AppKit
import Observation

/// The sidebar tunables workspace rows draw from (agent mark, presence dots,
/// row badge, stack size, the status icon's side; the session rows read the side),
/// observed once for every row. Each `WorkspaceRowView.configure` used to arm
/// its own observation, so every status tick left one more registration
/// behind; now a change redraws the live rows from one registration.
@MainActor
final class SidebarTunablesWatch {
    static let shared = SidebarTunablesWatch()

    typealias Values = (agentMark: SidebarAgentMarkVariant, presenceDots: Bool, rowBadge: SidebarRowBadgeStyle, stackCap: SidebarRowBadgeStackCap,
                        workspaceTitleMotion: SidebarWorkspaceTitleMotionVariant, statusSide: SidebarStatusIconSide)

    private let rows = NSHashTable<WorkspaceRowView>.weakObjects()
    private let tabRows = NSHashTable<SidebarTabRowView>.weakObjects()
    private var current: Values?

    /// The current values; `row` is redrawn when one changes.
    func values(for row: WorkspaceRowView) -> Values {
        rows.add(row)
        return values()
    }

    /// The current values; the session row `row` is redrawn when one changes.
    func values(for row: SidebarTabRowView) -> Values {
        tabRows.add(row)
        return values()
    }

    private func values() -> Values {
        if let current { return current }
        let values = withObservationTracking {
            (SidebarTunables.agentMark.value, SidebarTunables.presenceDots.value, SidebarRowBadgeStyle.tunable.value,
             SidebarRowBadgeStackCap.tunable.value, SidebarTunables.workspaceTitleMotion.value, SidebarStatusIconSide.tunable.value)
        } onChange: {
            Task { @MainActor in SidebarTunablesWatch.shared.changed() }
        }
        current = values
        return values
    }

    /// Drops the cached values and redraws the live rows. The observation
    /// runs this one main-actor hop after a change; a test that sets a
    /// tunable and draws a row in the same turn calls it right after the set.
    func changed() {
        current = nil
        for row in rows.allObjects { row.redrawLastConfiguration() }
        for row in tabRows.allObjects { row.redrawLastConfiguration() }
    }
}
