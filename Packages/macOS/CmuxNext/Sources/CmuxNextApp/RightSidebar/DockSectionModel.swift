import CmuxNextLayout
import Observation

/// The Dock section's rows: the docked columns of a window's shown screen
/// (plans/cmux-next/dock-column.md), in the order the window shows them.
@MainActor
@Observable
final class DockSectionModel {
    private(set) var rows: [DockSectionRow] = []

    /// Rebuilds the rows from `columns`; `title` names a pane's selected tab.
    func update(columns: [LayoutColumn], title: (PaneID) -> String?) {
        let next = columns.compactMap { column -> DockSectionRow? in
            guard let dock = column.dock, let pane = column.root.panes.first else { return nil }
            return DockSectionRow(id: column.id.rawValue, edge: dock.edge, pane: pane.rawValue,
                                  title: title(pane) ?? RightSidebarStrings.untitledPane)
        }
        if next != rows { rows = next }
    }
}
