import SwiftUI
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
    var dropIndicatorUsesTopLevelRows = false
    /// True while the `debug.sidebar.simulate_drag` debug-only V2 method is
    /// driving the drag state. The lifecycle observers honor this by not
    /// starting `SidebarDragFailsafeMonitor` (which would otherwise post a
    /// `mouse_up_failsafe` clear request immediately since no real mouse is
    /// pressed during simulation). DEBUG-only by convention; never set in
    /// release flows.
    var isSimulated: Bool = false

    init() {}

    func beginDragging(tabId: UUID) {
        draggedTabId = tabId
        clearDropIndicator()
    }

    func setDropIndicator(_ indicator: SidebarDropIndicator?, usesTopLevelRows: Bool = false) {
        dropIndicator = indicator
        dropIndicatorUsesTopLevelRows = indicator != nil && usesTopLevelRows
    }

    func clearDropIndicator() {
        setDropIndicator(nil)
    }

    func clearDrag() {
        draggedTabId = nil
        clearDropIndicator()
    }
}

#if DEBUG
/// Debug-only registry that exposes the live `SidebarDragState` of each
/// mounted `VerticalTabsSidebar` keyed by `windowId`. The debug-socket
/// `debug.sidebar.simulate_drag` handler reads from this so external
/// profiling tools (e.g. the `profile-pr` skill driving `xctrace`) can
/// generate deterministic drag-state mutations against the running app
/// without HID synthesis.
@MainActor
enum SidebarDragStateRegistry {
    private static var statesByWindowId: [UUID: SidebarDragState] = [:]

    static func register(windowId: UUID, dragState: SidebarDragState) {
        statesByWindowId[windowId] = dragState
    }

    static func unregister(windowId: UUID) {
        statesByWindowId.removeValue(forKey: windowId)
    }

    static func state(forWindowId windowId: UUID) -> SidebarDragState? {
        statesByWindowId[windowId]
    }

    static func registeredWindowIds() -> [UUID] {
        Array(statesByWindowId.keys)
    }
}
#endif

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

struct SidebarWorkspaceTopDropIndicator: View {
    let isVisible: Bool
    let isFirstRow: Bool
    let rowSpacing: CGFloat

    var body: some View {
        if isVisible {
            Rectangle()
                .fill(cmuxAccentColor())
                .frame(height: 2)
                .padding(.horizontal, 8)
                .offset(y: isFirstRow ? 0 : -(rowSpacing / 2))
        }
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
