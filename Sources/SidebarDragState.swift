import AppKit
import CmuxSocketControl
import Bonsplit
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


// MARK: - Sidebar drag state, registries, lifecycle, failsafe
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

struct SidebarWorkspaceFrameAnchorModifier: ViewModifier {
    let id: UUID
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.anchorPreference(key: SidebarWorkspaceRowFramePreferenceKey.self, value: .bounds) { anchor in
                [id: anchor]
            }
        } else {
            content
        }
    }
}

extension View {
    func sidebarWorkspaceFrameAnchor(id: UUID, isEnabled: Bool) -> some View {
        modifier(SidebarWorkspaceFrameAnchorModifier(id: id, isEnabled: isEnabled))
    }
}

struct SidebarWorkspaceRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
    }
}

enum SidebarDragLifecycleNotification {
    static let stateDidChange = Notification.Name("cmux.sidebarDragStateDidChange")
    static let requestClear = Notification.Name("cmux.sidebarDragRequestClear")
    private static let tabIdKey = "tabId"
    private static let reasonKey = "reason"

    static func postStateDidChange(tabId: UUID?, reason: String) {
        var userInfo: [AnyHashable: Any] = [reasonKey: reason]
        if let tabId {
            userInfo[tabIdKey] = tabId
        }
        NotificationCenter.default.post(
            name: stateDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    static func postClearRequest(reason: String) {
        NotificationCenter.default.post(
            name: requestClear,
            object: nil,
            userInfo: [reasonKey: reason]
        )
    }

    static func tabId(from notification: Notification) -> UUID? {
        notification.userInfo?[tabIdKey] as? UUID
    }

    static func reason(from notification: Notification) -> String {
        notification.userInfo?[reasonKey] as? String ?? "unknown"
    }
}

enum SidebarOutsideDropResetPolicy {
    static func shouldResetDrag(draggedTabId: UUID?, hasSidebarDragPayload: Bool) -> Bool {
        draggedTabId != nil && hasSidebarDragPayload
    }
}

enum SidebarDragFailsafePolicy {
    static let clearDelay: TimeInterval = 0.15

    static func shouldRequestClear(isDragActive: Bool, isLeftMouseButtonDown: Bool) -> Bool {
        isDragActive && !isLeftMouseButtonDown
    }

    static func shouldRequestClearWhenMonitoringStarts(isLeftMouseButtonDown: Bool) -> Bool {
        shouldRequestClear(
            isDragActive: true,
            isLeftMouseButtonDown: isLeftMouseButtonDown
        )
    }

    static func shouldRequestClear(forMouseEventType eventType: NSEvent.EventType) -> Bool {
        eventType == .leftMouseUp
    }
}

@MainActor
@Observable
final class SidebarDragFailsafeMonitor {
    private static let escapeKeyCode: UInt16 = 53
    private var pendingClearWorkItem: DispatchWorkItem?
    var appResignObserver: NSObjectProtocol?
    var keyDownMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var onRequestClear: ((String) -> Void)?

    func start(onRequestClear: @escaping (String) -> Void) {
        self.onRequestClear = onRequestClear
        if SidebarDragFailsafePolicy.shouldRequestClearWhenMonitoringStarts(
            isLeftMouseButtonDown: CGEventSource.buttonState(
                .combinedSessionState,
                button: .left
            )
        ) {
            requestClearSoon(reason: "mouse_up_failsafe")
        }
        if appResignObserver == nil {
            appResignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "app_resign_active")
                }
            }
        }
        if keyDownMonitor == nil {
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == Self.escapeKeyCode {
                    self?.requestClearSoon(reason: "escape_cancel")
                }
                return event
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                if SidebarDragFailsafePolicy.shouldRequestClear(forMouseEventType: event.type) {
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
                return event
            }
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard SidebarDragFailsafePolicy.shouldRequestClear(forMouseEventType: event.type) else { return }
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
            }
        }
    }

    func stop() {
        pendingClearWorkItem?.cancel()
        pendingClearWorkItem = nil
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        onRequestClear = nil
    }

    private func requestClearSoon(reason: String) {
        guard pendingClearWorkItem == nil else { return }
#if DEBUG
        cmuxDebugLog("sidebar.dragFailsafe.schedule reason=\(reason)")
#endif
        let workItem = DispatchWorkItem { [weak self] in
#if DEBUG
            cmuxDebugLog("sidebar.dragFailsafe.fire reason=\(reason)")
#endif
            self?.pendingClearWorkItem = nil
            self?.onRequestClear?(reason)
        }
        pendingClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarDragFailsafePolicy.clearDelay, execute: workItem)
    }
}

struct SidebarExternalDropOverlay: View {
    let draggedTabId: UUID?

    var body: some View {
        let dragPasteboardTypes = NSPasteboard(name: .drag).types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureSidebarExternalOverlay(
            draggedTabId: draggedTabId,
            pasteboardTypes: dragPasteboardTypes
        )
        Group {
            if shouldCapture {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .onDrop(
                        of: SidebarTabDragPayload.dropContentTypes,
                        delegate: SidebarExternalDropDelegate(draggedTabId: draggedTabId)
                    )
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct SidebarExternalDropDelegate: DropDelegate {
    let draggedTabId: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        let hasSidebarPayload = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        let shouldReset = SidebarOutsideDropResetPolicy.shouldResetDrag(
            draggedTabId: draggedTabId,
            hasSidebarDragPayload: hasSidebarPayload
        )
#if DEBUG
        cmuxDebugLog(
            "sidebar.dropOutside.validate tab=\(debugShortSidebarTabId(draggedTabId)) " +
            "hasType=\(hasSidebarPayload) allowed=\(shouldReset)"
        )
#endif
        return shouldReset
    }

    func dropEntered(info: DropInfo) {
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.entered tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
    }

    func dropExited(info: DropInfo) {
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.exited tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.updated tab=\(debugShortSidebarTabId(draggedTabId)) op=move")
#endif
        // Explicit move proposal avoids AppKit showing a copy (+) cursor.
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.perform tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
        SidebarDragLifecycleNotification.postClearRequest(reason: "outside_sidebar_drop")
        return true
    }

    func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

