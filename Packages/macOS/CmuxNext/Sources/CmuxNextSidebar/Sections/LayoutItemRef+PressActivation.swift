import Foundation

extension LayoutItemRef {
    /// True when a sidebar item with this ref opens on mouse-down, as a workspace row and a pane tab do.
    ///
    /// The one press policy of every sidebar item: the band, a block's tiles and the list's item rows
    /// all read it (`SidebarItemRowView`, `SidebarListView+Mouse`). A plain click opens on the press
    /// (Lawrence 2026-10-19: "mouse down to immediately open"): Home, the App Store, Settings and the
    /// other built-in pages, a pinned workspace, tab or space, a link, a saved group, an app. A press
    /// that turns into a drag still moves the item (the open already happened, as with a dragged
    /// workspace row). Only a new-tab launcher acts on release: it makes a tab, so a press the user
    /// meant as a move must not make one. A kind (or built-in) this client does not know acts on release.
    var activatesOnPress: Bool {
        if let builtIn {
            switch builtIn {
            case .newTerminal, .newBrowser, .newAgentChat: return false
            default: return true
            }
        }
        switch kind {
        case Self.workspaceKind, Self.tabKind, Self.roomKind, Self.urlKind, Self.savedGroupKind, Self.appKind:
            return true
        default:
            return false
        }
    }
}
