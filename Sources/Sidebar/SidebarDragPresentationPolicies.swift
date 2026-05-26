import Foundation
import Observation

/// Transient sidebar drag/drop state, owned by `VerticalTabsSidebar` and passed
/// by reference into rows and drop delegates. `@Observable` gives per-property
/// tracking: writing `draggedTabId` or `dropIndicator` during drag invalidates
/// only the views that read those properties (the dragged row's opacity and the
/// drop-indicator overlays), never the sidebar body or the `LazyVStack` itself.
/// That invariant is what prevents the layout-invalidation loop that caused
/// https://github.com/manaflow-ai/cmux/issues/2586.
@MainActor
@Observable
final class SidebarDragState {
    var draggedTabId: UUID?
    var dropIndicator: SidebarDropIndicator?

    init() {}
}

/// Per-row drop-indicator visibility, computed by the parent from value
/// inputs only. Takes UUIDs (not `Tab` objects or `SidebarDragState`) so it's
/// trivially unit-testable and the row's view subtree never reads the
/// `@Observable` store directly. Same predicate that used to live inside
/// `SidebarTabDropIndicatorOverlay`.
enum SidebarTabDropIndicatorPredicate {
    static func topVisible(
        forTabId tabId: UUID,
        draggedTabId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        tabIds: [UUID]
    ) -> Bool {
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        if indicator.tabId == tabId && indicator.edge == .top {
            return true
        }
        guard indicator.edge == .bottom,
              let currentIndex = tabIds.firstIndex(of: tabId),
              currentIndex > 0
        else {
            return false
        }
        return tabIds[currentIndex - 1] == indicator.tabId
    }

    /// Convenience used by `SidebarEmptyArea`: the empty area's "top" indicator
    /// (drawn above the empty space below all rows) is visible when the drop
    /// indicator targets nothing (end-of-list) or the bottom edge of the last
    /// row.
    static func emptyAreaTopVisible(
        draggedTabId: UUID?,
        dropIndicator: SidebarDropIndicator?,
        lastTabId: UUID?
    ) -> Bool {
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastTabId else { return false }
        return indicator.tabId == lastTabId
    }
}

/// Freezes `showsModifierShortcutHints` for the row whose context menu is open,
/// so pressing/releasing the modifier key while the menu is up does not flip
/// the underlying row's shortcut badges (which would be visible around the
/// open context menu). All other rows transition live.
enum SidebarShortcutHintFreezePolicy {
    static func resolved(
        live: Bool,
        currentTabId: UUID,
        frozenTabId: UUID?,
        frozenValue: Bool
    ) -> Bool {
        if frozenTabId == currentTabId {
            return frozenValue
        }
        return live
    }
}
