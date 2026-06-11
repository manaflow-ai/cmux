import SwiftUI

/// Shared animation timings for workspace-group structure changes in the
/// sidebar (promote-in-place, ungroup, collapse/expand, member join/leave,
/// drag-reorder settle).
///
/// One source of truth so every entrypoint that mutates group structure
/// (keyboard shortcut, context menu, group-header buttons, drag-and-drop,
/// socket/CLI) animates identically. The `TabManager` group mutation methods
/// wrap their structural changes in `withAnimation(SidebarGroupAnimation.<case>)`,
/// and the sidebar rows carry `.transition(.sidebarGroupRow)` so inserted or
/// removed rows fade while their siblings reflow within the same transaction.
enum SidebarGroupAnimation {
    /// Workspace row morphs into a group header (and back), member rows join or
    /// leave a group, drag-reorder drops settle.
    static let structure: Animation = .snappy(duration: 0.26)

    /// Group collapse / expand: member rows slide+fade and the chevron rotates.
    static let collapse: Animation = .snappy(duration: 0.24)
}

extension AnyTransition {
    /// Transition for a sidebar row appearing or disappearing because of a
    /// group-structure change. A plain opacity fade keeps the morph between a
    /// workspace row and a group header (same ForEach identity, swapped
    /// `_ConditionalContent` branch) reading as a crossfade, while the
    /// surrounding `withAnimation` transaction animates the list reflow so
    /// collapse/expand and member join/leave feel like a slide for free.
    static var sidebarGroupRow: AnyTransition {
        .opacity
    }
}
