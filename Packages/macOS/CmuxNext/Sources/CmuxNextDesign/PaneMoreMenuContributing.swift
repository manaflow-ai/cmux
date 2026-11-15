public import AppKit

/// A pane's hosted view that adds its own rows to the top of the pane's menus, its tab bar's right-click and its
/// selected tab's (`PaneToolbar.tabBarMenuRows()`), instead of drawing a ⋮ of its own (Lawrence 2026-10-22: "fix it
/// so it's simple, like tf are these buttons for"; the pane's own ⋮ is gone too, user 2026-11-13). The docked
/// Home's Chief puts Chief Actions and its Subagents there.
@MainActor
public protocol PaneMoreMenuContributing: AnyObject {
    /// Fresh rows for the pane's menus, first in them, above a separator; empty adds nothing.
    func paneMoreMenuItems() -> [NSMenuItem]
}
