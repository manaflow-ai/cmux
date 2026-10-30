public import AppKit

/// A pane's hosted view that adds its own rows to the top of the pane's one more menu (⋮,
/// `PaneToolbar`), instead of drawing a second ⋮ of its own (Lawrence 2026-10-22: "fix it so it's
/// simple, like tf are these buttons for"). The docked Home's Chief puts Chief Actions and its
/// Subagents there.
@MainActor
public protocol PaneMoreMenuContributing: AnyObject {
    /// Fresh rows for the pane's more menu, first in it, above a separator; empty adds nothing.
    func paneMoreMenuItems() -> [NSMenuItem]
}
