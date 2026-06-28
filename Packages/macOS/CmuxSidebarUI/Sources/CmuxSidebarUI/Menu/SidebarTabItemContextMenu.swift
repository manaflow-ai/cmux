public import SwiftUI

/// The sidebar workspace row's full right-click context menu plus the
/// menu-presentation lifecycle hooks the row attaches to it.
///
/// `TabItemView` renders this from its `.contextMenu { }` builder: the view
/// composes the lifted ``SidebarWorkspaceContextMenu`` (which projects the
/// precomputed ``SidebarWorkspaceContextMenuData`` snapshot and the
/// ``SidebarWorkspaceContextMenuActions`` closure bundle) and forwards SwiftUI's
/// `onAppear`/`onDisappear` to the row's app-side menu-tracking callbacks.
///
/// Pulling this combinator out of the row collapses the god-file `.contextMenu`
/// body to a single value-typed view call. The `data` snapshot and `actions`
/// bundle are still assembled by the row, because they read the live
/// tab-manager, notification store, and app-delegate and must stay app-side per
/// the list snapshot-boundary rule; only their package-safe projection and the
/// menu lifecycle live here.
public struct SidebarTabItemContextMenu: View {
    private let data: SidebarWorkspaceContextMenuData
    private let actions: SidebarWorkspaceContextMenuActions
    private let onMenuAppear: () -> Void
    private let onMenuDisappear: () -> Void

    /// Creates the row context-menu combinator.
    /// - Parameters:
    ///   - data: Immutable snapshot of every label, id, flag, and submenu list the menu renders.
    ///   - actions: Closure bundle invoked by the menu's buttons.
    ///   - onMenuAppear: Invoked when the context menu becomes visible.
    ///   - onMenuDisappear: Invoked when the context menu is dismissed.
    public init(
        data: SidebarWorkspaceContextMenuData,
        actions: SidebarWorkspaceContextMenuActions,
        onMenuAppear: @escaping () -> Void,
        onMenuDisappear: @escaping () -> Void
    ) {
        self.data = data
        self.actions = actions
        self.onMenuAppear = onMenuAppear
        self.onMenuDisappear = onMenuDisappear
    }

    public var body: some View {
        SidebarWorkspaceContextMenu(data: data, actions: actions)
            .onAppear(perform: onMenuAppear)
            .onDisappear(perform: onMenuDisappear)
    }
}
