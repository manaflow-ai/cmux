import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

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

    /// True only in the window that *originated* the current drag (set via
    /// ``beginDragging(tabId:)``). A destination window that mirrors a foreign
    /// drag id into ``draggedTabId`` for cross-window rendering does not own the
    /// process-wide ``SidebarWorkspaceDragRegistry`` entry, so it must not clear
    /// it when its own local drag state is reset.
    private var originatedActiveDrag = false

    /// Pin state of a foreign (cross-window) dragged workspace, resolved once
    /// when the drag is mirrored into this window and reused for every hover
    /// update. A workspace's pin state can't change mid-drag, so this avoids an
    /// `AppDelegate.tabManagerFor(tabId:)` scan over every window on each
    /// pointer-move. `nil` when no foreign drag is mirrored here.
    var foreignDraggedIsPinned: Bool?

    init() {}

    func beginDragging(tabId: UUID) {
        draggedTabId = tabId
        clearDropIndicator()
        originatedActiveDrag = true
        SidebarWorkspaceDragRegistry.begin(workspaceId: tabId)
    }

    func setDropIndicator(_ indicator: SidebarDropIndicator?, usesTopLevelRows: Bool = false) {
        dropIndicator = indicator
        dropIndicatorUsesTopLevelRows = indicator != nil && usesTopLevelRows
    }

    func clearDropIndicator() {
        setDropIndicator(nil)
    }

    func clearDrag() {
        if originatedActiveDrag, let draggedTabId {
            SidebarWorkspaceDragRegistry.end(workspaceId: draggedTabId)
        }
        originatedActiveDrag = false
        foreignDraggedIsPinned = nil
        draggedTabId = nil
        clearDropIndicator()
    }
}

/// Process-wide identity of the workspace currently being dragged in any
/// window's sidebar.
///
/// A sidebar drag is a single, process-global event: at most one workspace is
/// being dragged at a time. The originating window records it here synchronously
/// at drag start (``SidebarDragState/beginDragging(tabId:)``) and clears it when
/// that drag ends. A *destination* window — which has no local
/// ``SidebarDragState/draggedTabId`` because the drag began elsewhere — reads
/// this to resolve the dragged workspace for a cross-window move.
///
/// This is deliberately not sourced from `NSPasteboard(name: .drag)`: SwiftUI's
/// `.onDrag` registers the payload through an `NSItemProvider` whose data
/// representation is delivered asynchronously, so a synchronous pasteboard read
/// inside a `DropDelegate` can race and return `nil`. A plain in-process value,
/// set synchronously on the main actor, has no such materialization race.
@MainActor
enum SidebarWorkspaceDragRegistry {
    private static var activeWorkspaceId: UUID?

    /// The workspace currently being sidebar-dragged anywhere in the process,
    /// or `nil` when no sidebar drag is in flight.
    static var currentWorkspaceId: UUID? { activeWorkspaceId }

    /// Record the start of a sidebar drag. Called by the originating window.
    static func begin(workspaceId: UUID) {
        activeWorkspaceId = workspaceId
    }

    /// Clear the active drag, but only if `workspaceId` still matches the
    /// in-flight drag, so a stale clear from a superseded drag is a no-op.
    static func end(workspaceId: UUID) {
        if activeWorkspaceId == workspaceId {
            activeWorkspaceId = nil
        }
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
