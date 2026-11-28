public import Foundation

/// A classic tab and the daemon tab the import made for it, at its place in its pane.
public struct ClassicPlacedTab: Sendable {
    public var pane: PaneID
    public var index: Int
    public var surface: SurfaceID
    public var tab: ClassicSessionTab?

    public init(pane: PaneID, index: Int, surface: SurfaceID, tab: ClassicSessionTab? = nil) {
        self.pane = pane
        self.index = index
        self.surface = surface
        self.tab = tab
    }
}

/// How one imported pane is left as classic left it: the tab it selected and whether it was the focused one.
public struct ClassicPaneSelection: Sendable, Equatable {
    public var pane: PaneID
    /// The surface classic's selected tab became; nil when the pane had one tab (nothing to select).
    public var selected: SurfaceID?
    public var focused: Bool
}

extension WorkspaceShape.Screen {
    /// Its panes in layout order: the order the import builds a classic layout's panes in.
    public var orderedPanes: [WorkspaceShape.Pane] {
        layout.paneIDs.compactMap { id in panes.first { $0.handle == id } }
    }
}

extension ClassicSessionLayout {
    /// Whether anything of a pane's state is left to restore after the build: a focus or a tab to select or pin.
    public var restoresPanes: Bool { panes.contains { $0.focused || $0.tabs.count > 1 } }

    /// The surfaces to pin, in order: each pane's pinned tabs, matched to `panes` (the built screen's, in layout order) by index.
    public func pinned(in panes: [WorkspaceShape.Pane]) -> [SurfaceID] {
        zip(self.panes, panes).flatMap { saved, pane in
            zip(saved.tabs, pane.surfaces).filter { $0.0.pinned }.map(\.1)
        }
    }

    /// Each pane's selection and focus once its pinned tabs moved to the front (cmux NEXT sorts pinned tabs
    /// first, as classic drew them), matched to `panes` read after the pins by index.
    public func selections(in panes: [WorkspaceShape.Pane]) -> [ClassicPaneSelection] {
        zip(self.panes, panes).map { saved, pane in
            // By index, not by value: two tabs alike (two shells in one folder) stay apart.
            let tabs = saved.tabs.enumerated()
            let order = tabs.filter { $0.element.pinned }.map(\.offset) + tabs.filter { !$0.element.pinned }.map(\.offset)
            let index = order.firstIndex(of: saved.selectedTab)
            let selected = saved.tabs.count > 1 ? index.flatMap { pane.surfaces.dropFirst($0).first } : nil
            return ClassicPaneSelection(pane: pane.handle, selected: selected, focused: saved.focused)
        }
    }
}
