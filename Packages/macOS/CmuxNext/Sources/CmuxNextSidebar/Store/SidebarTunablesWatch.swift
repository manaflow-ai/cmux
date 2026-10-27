import AppKit
import Observation

/// The sidebar tunables workspace rows draw from (agent mark, presence dots,
/// row badge, stack size, quiet unnamed rows, the row name),
/// observed once for every row. Each `WorkspaceRowView.configure` used to arm
/// its own observation, so every status tick left one more registration
/// behind; now a change redraws the live rows from one registration.
@MainActor
final class SidebarTunablesWatch {
    static let shared = SidebarTunablesWatch()

    typealias Values = (agentMark: SidebarAgentMarkVariant, presenceDots: Bool, rowBadge: SidebarRowBadgeStyle, stackCap: SidebarRowBadgeStackCap, workspaceTitleMotion: SidebarWorkspaceTitleMotionVariant, quietUnnamedRows: Bool,
                         rowTitle: SidebarRowTitleMode, rowTitleSingleChat: Bool)

    private let rows = NSHashTable<WorkspaceRowView>.weakObjects()
    private var current: Values?

    /// The current values; `row` is redrawn when one changes.
    func values(for row: WorkspaceRowView) -> Values {
        rows.add(row)
        if let current { return current }
        let values = withObservationTracking {
            (SidebarTunables.agentMark.value, SidebarTunables.presenceDots.value, SidebarRowBadgeStyle.tunable.value,
             SidebarRowBadgeStackCap.tunable.value, SidebarTunables.workspaceTitleMotion.value, SidebarTunables.quietUnnamedRows.value,
             SidebarTunables.rowTitle.value, SidebarTunables.rowTitleSingleChat.value)
        } onChange: {
            Task { @MainActor in SidebarTunablesWatch.shared.changed() }
        }
        current = values
        return values
    }

    private let tabRows = NSHashTable<SidebarTabRowView>.weakObjects()
    private var tabLook: SidebarTabLineLook?

    /// The listed tab rows' look (`sidebar.tabLines`); `row` is redrawn when it changes.
    func tabLook(for row: SidebarTabRowView) -> SidebarTabLineLook {
        tabRows.add(row)
        if let tabLook { return tabLook }
        let look = withObservationTracking { SidebarTunables.tabLines.value } onChange: {
            Task { @MainActor in SidebarTunablesWatch.shared.changed() }
        }
        tabLook = look
        return look
    }

    /// Drops the cached values and redraws the live rows. The observation
    /// runs this one main-actor hop after a change; a test that sets a
    /// tunable and draws a row in the same turn calls it right after the set.
    func changed() {
        current = nil
        tabLook = nil
        for row in rows.allObjects { row.redrawLastConfiguration() }
        for row in tabRows.allObjects { row.redrawLastConfiguration() }
    }
}
