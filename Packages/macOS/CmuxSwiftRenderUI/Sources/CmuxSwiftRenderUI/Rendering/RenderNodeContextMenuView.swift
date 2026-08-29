import AppKit
import CmuxSwiftRender

/// Backing `NSView` for ``RenderNodeContextMenuOverlay`` that hit-tests only
/// context-menu clicks (right-click, control-click), letting left-click
/// taps and drags pass through to the SwiftUI row underneath — the same
/// event-filtered `hitTest` idiom as `MiddleClickCaptureView`.
final class RenderNodeContextMenuView: NSView {
    var nodes: [RenderNode] = [] {
        didSet {
            // A new IR snapshot invalidates the one-pass presence result.
            cachedMenuPresence = nil
        }
    }
    var dispatch: SidebarActionDispatch = .noop
    /// Pure menu-presence result for the current `nodes` snapshot. Hit
    /// testing can run more than once for one event, so keep the scan out of
    /// repeated descendant ownership checks until the overlay updates.
    private var cachedMenuPresence: Bool?
    /// Logical render-tree location of the row owning this overlay. The
    /// hosting view may flatten nested platform views into siblings, so this
    /// path is used to distinguish descendants from neighboring rows.
    var contextMenuPath: [Int] = []
    /// Mirrors the SwiftUI `isEnabled` environment at the overlay's position:
    /// `.disabled(true)` on the row or an ancestor suppresses the context
    /// menu entirely, matching how SwiftUI treats a disabled row's menu.
    var isMenuEnabled = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        // AppKit supplies `point` in this view's superview coordinate system.
        // Convert it once for the local bounds check, while retaining the
        // original point for descendant overlays in that same superview space.
        return evaluateHitTest(
            localPoint: convert(point, from: superview),
            superviewPoint: point,
            currentEvent: NSApp.currentEvent
        )
    }

    /// Deterministic event-filtered hit-test seam. The point is in this view's
    /// superview coordinate system, matching ``NSView.hitTest(_:)``. Production
    /// hit testing supplies the same point through the override above; tests
    /// can pass a synthetic event without relying on `NSApp.currentEvent`.
    func performHitTest(at pointInSuperview: NSPoint, currentEvent: NSEvent?) -> NSView? {
        guard let superview else { return nil }
        return evaluateHitTest(
            localPoint: convert(pointInSuperview, from: superview),
            superviewPoint: pointInSuperview,
            currentEvent: currentEvent
        )
    }

    private func evaluateHitTest(
        localPoint: NSPoint,
        superviewPoint: NSPoint,
        currentEvent: NSEvent?
    ) -> NSView? {
        guard bounds.contains(localPoint), let event = currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown:
            break
        case .leftMouseDown where event.modifierFlags.contains(.control):
            break
        default:
            return nil
        }
        // Ordinary pointer events are rejected above before walking the
        // render-tree menu IR. This keeps sidebar hit testing cheap while
        // moving, clicking, and dragging over rows.
        guard isMenuEnabled, hasPresentableMenuItems() else { return nil }
        // SwiftUI resolves the context menu of the view under the pointer,
        // so a nested `.contextMenu` inside this row must win over this
        // (topmost) overlay. Deferring lets AppKit's hit-test recursion
        // continue into the content subtree and reach the deeper overlay.
        // The descendant walk is expressed in the superview's coordinates,
        // which is also the coordinate system AppKit supplied to this method.
        if deeperOverlayClaims(superviewPoint) { return nil }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        present(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        present(with: event)
    }

    /// Presents the menu without a mouse event, anchored to the row: the
    /// VoiceOver `showMenu` action path (VO-Shift-M on the row's element).
    func presentFromAccessibility() {
        guard let menu = menuForPresentation() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY), in: self)
    }

    private func present(with event: NSEvent) {
        guard let menu = menuForPresentation() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// The on-demand menu, or nil when the row is disabled or the IR yields
    /// nothing presentable (no nodes, or separators only).
    func menuForPresentation() -> NSMenu? {
        let builder = RenderNodeContextMenuBuilder(dispatch: dispatch)
        guard isMenuEnabled else { return nil }
        // `append` returns the presence result while constructing each
        // submenu, so presentation does not pre-scan the same tree.
        return builder.makeMenuIfPresentable(nodes: nodes)
    }

    /// Returns the cached pure-data menu-presence result for this overlay.
    func hasPresentableMenuItems() -> Bool {
        if let cachedMenuPresence {
            return cachedMenuPresence
        }
        let result = RenderNodeContextMenuBuilder(dispatch: dispatch)
            .hasPresentableItems(nodes: nodes)
        cachedMenuPresence = result
        return result
    }

    /// Whether a descendant menu overlay also contains `point` (in the
    /// superview's coordinate space). SwiftUI may flatten platform views into
    /// siblings, so the render path filters out neighboring rows.
    func deeperOverlayClaims(_ point: NSPoint) -> Bool {
        guard let superview else { return false }
        return subtreeContainsClaimingOverlay(
            superview,
            excluding: self,
            point: point,
            space: superview,
            ancestorPath: contextMenuPath
        )
    }
}

/// Depth-first search for another ``RenderNodeContextMenuView`` under `root`
/// whose strict render-path descendant bounds contain `point` (expressed in
/// `space`'s coordinates) and whose menu IR is non-empty.
@MainActor
private func subtreeContainsClaimingOverlay(
    _ root: NSView,
    excluding excluded: NSView,
    point: NSPoint,
    space: NSView,
    ancestorPath: [Int]
) -> Bool {
    for subview in root.subviews {
        if subview === excluded || subview.isHidden { continue }
        if let overlay = subview as? RenderNodeContextMenuView {
            let local = overlay.convert(point, from: space)
            let isStrictDescendant = overlay.contextMenuPath.count > ancestorPath.count
                && overlay.contextMenuPath.starts(with: ancestorPath)
            if isStrictDescendant,
               overlay.bounds.contains(local),
               overlay.isMenuEnabled,
               overlay.hasPresentableMenuItems() {
                return true
            }
            // An unrelated overlay can itself contain platform descendants;
            // do not cross that ownership boundary while looking for this
            // row's nested menu.
            continue
        }
        if subtreeContainsClaimingOverlay(
            subview,
            excluding: excluded,
            point: point,
            space: space,
            ancestorPath: ancestorPath
        ) {
            return true
        }
    }
    return false
}
