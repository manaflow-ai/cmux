import AppKit
import SwiftUI

/// Single main-actor owner for AppKit-native sidebar tab/group drag sessions.
///
/// The sidebar rows reference this coordinator below the `LazyVStack` boundary,
/// so it is deliberately a plain class — **not** `@Observable` — to avoid
/// triggering body invalidation (see issue #2586). All drag-state writes happen
/// in the injected `onDragBegin`/`onDragEnd` closures (event-driven, like the
/// `.onDrag` behavior it replaces), never from view-body evaluation.
///
/// Mirrors `SessionDragCoordinator`'s injectable `startDraggingSession` seam so
/// focused tests can capture the started session without a live window.
@MainActor
final class SidebarTabDragSourceCoordinator {
    typealias DragAction = @MainActor (UUID) -> Void
    typealias DragImage = @MainActor (NSView, NSRect) -> NSImage?
    typealias StartDraggingSession = @MainActor (
        _ sourceView: NSView,
        _ item: NSDraggingItem,
        _ event: NSEvent,
        _ source: SidebarTabDragSessionSource
    ) -> Void

    /// Per-workspace anchors, keyed so each row's drag resolves to the anchor
    /// covering that row — not whichever row most recently re-rendered.
    ///
    /// Anchors are retained **strongly** (not weak): SwiftUI can release an
    /// `.overlay`-hosted NSViewRepresentable's view after the render pass on
    /// some macOS versions, and a weak ref would silently nil out — every drag
    /// would then look up a missing anchor. Rows re-register on every
    /// `updateNSView` and unregister on `dismantleNSView`, so the set is
    /// bounded by the number of rows currently in the hierarchy.
    private var anchors: [UUID: NSView] = [:]
    /// Reverse index of `anchors` (view identity -> workspace id) so recycled-
    /// view cleanup and dismantle-driven unregistration stay O(1) per row
    /// instead of scanning every registered anchor on each `updateNSView`.
    private var workspaceIdsByView: [ObjectIdentifier: UUID] = [:]
    /// Window-base frame of each anchor, captured while it was attached to a
    /// window. An `.overlay`-hosted anchor can be detached by a re-render
    /// during/after a drag (the row's drag-state opacity flip); the captured
    /// frame keeps the dragging-item frame and preview correct after that.
    private var anchorWindowFrames: [UUID: NSRect] = [:]
    /// The window each frame was captured in (weak: never keeps a closed
    /// window alive). Paired with `anchorWindowFrames` so the detached-anchor
    /// fallback can only ever resolve to the window the row actually lived in —
    /// never an ambient guess like `NSApp.keyWindow`.
    private var anchorWindows: [UUID: WeakWindowBox] = [:]
    private var activeSource: SidebarTabDragSessionSource?

    /// Runs when a drag starts. Wired once by the sidebar owner to
    /// `dragState.beginDragging(tabId:)`, arming row opacity and the failsafe.
    var onDragBegin: DragAction

    /// Runs when the native session concludes. Wired once by the sidebar owner
    /// to `dragState.clearDrag()` — symmetric with `onDragBegin`, so the
    /// coordinator never owns a second (notification) path into drag state.
    /// Defaults to a no-op for tests that only exercise session mechanics.
    var onDragEnd: DragAction

    private let startDraggingSession: StartDraggingSession

    /// Creates a coordinator with injectable lifecycle seams. The sidebar owner
    /// wires `onDragBegin`/`onDragEnd` to `SidebarDragState`; tests substitute
    /// `startDraggingSession` to capture started sessions without a live
    /// window.
    init(
        onDragBegin: @escaping DragAction = { _ in },
        onDragEnd: @escaping DragAction = { _ in },
        startDraggingSession: @escaping StartDraggingSession = { sourceView, item, event, source in
            sourceView.beginDraggingSession(with: [item], event: event, source: source)
        }
    ) {
        self.onDragBegin = onDragBegin
        self.onDragEnd = onDragEnd
        self.startDraggingSession = startDraggingSession
    }

    /// Registers (or re-registers) the anchor covering `workspaceId`'s row.
    ///
    /// A LazyVStack can recycle one anchor view onto a different workspace, and
    /// SwiftUI can replace a row's anchor view without a matching dismantle
    /// order. Both cases are resolved through the reverse index: the view's
    /// previous id (if any) is retired here, and a frame left over from a
    /// different view under the same id is dropped so the next drag cannot use
    /// stale geometry.
    func registerAnchor(_ view: NSView, for workspaceId: UUID) {
        let viewKey = ObjectIdentifier(view)
        if let previousId = workspaceIdsByView[viewKey], previousId != workspaceId {
            // The view was recycled onto a new workspace: retire the old id's
            // entry so it cannot keep this view (and its frame) alive.
            anchors.removeValue(forKey: previousId)
            anchorWindowFrames.removeValue(forKey: previousId)
            anchorWindows.removeValue(forKey: previousId)
            workspaceIdsByView.removeValue(forKey: viewKey)
        }
        if let previousView = anchors[workspaceId], previousView !== view {
            // A different view is taking over this workspace: its cached frame
            // describes the old view's geometry, not the replacement's.
            workspaceIdsByView.removeValue(forKey: ObjectIdentifier(previousView))
            anchorWindowFrames.removeValue(forKey: workspaceId)
            anchorWindows.removeValue(forKey: workspaceId)
        }
        anchors[workspaceId] = view
        workspaceIdsByView[viewKey] = workspaceId
        if let window = view.window {
            anchorWindowFrames[workspaceId] = view.convert(view.bounds, to: nil)
            anchorWindows[workspaceId] = WeakWindowBox(window: window)
        }
    }

    /// Removes a dismantled anchor's registration — but only if the registered
    /// anchor still *is* that view. SwiftUI can replace a row's anchor view and
    /// register the replacement before the old view's `dismantleNSView` runs;
    /// removing by workspace id alone would then delete the live replacement.
    /// The view identity check keeps teardown scoped to the retired view.
    ///
    /// Called from `SidebarTabDragAnchorView.dismantleNSView`, which SwiftUI
    /// invokes only when the row leaves the hierarchy — not on the transient
    /// window detaches a re-render causes mid-drag, so the detached-drag
    /// fallback keeps its cached frame.
    func unregisterAnchor(_ view: NSView) {
        let viewKey = ObjectIdentifier(view)
        guard let workspaceId = workspaceIdsByView[viewKey] else { return }
        guard anchors[workspaceId] === view else {
            workspaceIdsByView.removeValue(forKey: viewKey)
            return
        }
        anchors.removeValue(forKey: workspaceId)
        anchorWindowFrames.removeValue(forKey: workspaceId)
        anchorWindows.removeValue(forKey: workspaceId)
        workspaceIdsByView.removeValue(forKey: viewKey)
    }

    /// The anchor currently registered for `workspaceId`'s row, if that row is
    /// in the hierarchy.
    func anchor(for workspaceId: UUID) -> NSView? {
        anchors[workspaceId]
    }

    /// Window-base frame of `workspaceId`'s anchor, captured while attached.
    /// Used by `dragEvent(for:location:)` to synthesize a correct event location
    /// when the anchor has been detached from its window.
    func windowFrame(for workspaceId: UUID) -> NSRect? {
        anchorWindowFrames[workspaceId]
    }

    /// Called by the anchor NSView on every attach/detach so the window-frame
    /// cache tracks a re-attached overlay.
    func anchorDidMove(toWindow window: NSWindow?, for workspaceId: UUID) {
        if let window, let view = anchors[workspaceId] {
            anchorWindowFrames[workspaceId] = view.convert(view.bounds, to: nil)
            anchorWindows[workspaceId] = WeakWindowBox(window: window)
        }
    }

    /// The window `workspaceId`'s cached frame belongs to, if that window is
    /// still alive. Lets the detached-anchor drag resolve to the row's real
    /// window instead of an ambient guess.
    func cachedWindow(for workspaceId: UUID) -> NSWindow? {
        anchorWindows[workspaceId]?.window
    }

    /// Starts one AppKit drag session for `workspaceId`. Returns `false` when a
    /// session is already active (single-session guard) or no in-window source
    /// view exists (so a silent `beginDraggingSession` failure can never strand
    /// `activeSource`).
    @discardableResult
    func beginDrag(
        workspaceId: UUID,
        event: NSEvent,
        makeImage: @escaping DragImage
    ) -> Bool {
        guard activeSource == nil,
              let anchor = anchor(for: workspaceId),
              // No `NSApp.keyWindow` fallback: a key window that is not the
              // row's window (e.g. a settings panel that just became key) would
              // start the session in the wrong coordinate space. Fail closed
              // instead of starting an invalid drag.
              let window = anchor.window ?? event.window else {
            return false
        }

        // A re-render during/after a drag (e.g. the row's drag-state opacity
        // flip) can detach the `.overlay`-hosted anchor from its window. Fall
        // back to the window's live content view so the session still starts;
        // the dragging frame and preview use the frame captured while attached.
        let sourceView: NSView
        let frame: NSRect
        if anchor.window === window {
            sourceView = anchor
            frame = anchor.bounds
        } else if let contentView = window.contentView {
            sourceView = contentView
            let windowFrame = anchorWindowFrames[workspaceId]
                ?? NSRect(origin: .zero, size: anchor.bounds.size)
            frame = contentView.convert(windowFrame, from: nil)
        } else {
            sourceView = anchor
            frame = anchor.bounds
        }
        guard frame.width > 0, frame.height > 0 else {
            return false
        }

        onDragBegin(workspaceId)

        let source = SidebarTabDragSessionSource { [weak self] in
            guard let self else { return }
            self.activeSource = nil
            self.onDragEnd(workspaceId)
        }
        activeSource = source

        let item = NSDraggingItem(
            pasteboardWriter: SidebarTabDragPayload(tabId: workspaceId).pasteboardItem()
        )
        if let image = makeImage(sourceView, frame) {
            item.setDraggingFrame(frame, contents: image)
        }
        startDraggingSession(sourceView, item, event, source)
        return true
    }
}

// MARK: - Environment injection

/// Weak box so the coordinator's window cache never keeps a closed window
/// alive. A dictionary of `NSWindow?` would store optionals strongly; there is
/// no `weak` dictionary value in Swift.
private final class WeakWindowBox {
    weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
    }
}

private struct SidebarTabDragCoordinatorKey: EnvironmentKey {
    static let defaultValue: SidebarTabDragSourceCoordinator? = nil
}

extension EnvironmentValues {
    /// The sidebar-owned coordinator for AppKit-native tab/group drag sessions.
    ///
    /// Injected once above the `LazyVStack` boundary and read via `@Environment`
    /// inside rows, so lazy rows receive only value snapshots and action
    /// closures — no store property threading through every intermediate view.
    /// Environment values do not participate in row `==` comparisons, so the
    /// shared coordinator can never trigger row re-evaluation.
    var sidebarTabDragCoordinator: SidebarTabDragSourceCoordinator? {
        get { self[SidebarTabDragCoordinatorKey.self] }
        set { self[SidebarTabDragCoordinatorKey.self] = newValue }
    }
}
