import AppKit
import CmuxSwiftRender

/// Backing `NSView` for ``RenderNodeContextMenuOverlay`` that hit-tests only
/// context-menu clicks (right-click, control-click), letting left-click
/// taps and drags pass through to the SwiftUI row underneath — the same
/// event-filtered `hitTest` idiom as `MiddleClickCaptureView`.
final class RenderNodeContextMenuView: NSView {
    var nodes: [RenderNode] = []
    var dispatch: SidebarActionDispatch = .noop
    /// Mirrors the SwiftUI `isEnabled` environment at the overlay's position:
    /// `.disabled(true)` on the row or an ancestor suppresses the context
    /// menu entirely, matching how SwiftUI treats a disabled row's menu.
    var isMenuEnabled = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isMenuEnabled else { return nil }
        // AppKit's NSView.hitTest(_:) receives `point` in the SUPERVIEW's
        // coordinate system ("a point that is in the coordinate system of
        // the receiver's superview" — unlike UIKit's local-space
        // point(inside:)), so converting from the superview yields local
        // coordinates. Without a superview AppKit does not hit-test this
        // view; treat the point as local for safety.
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local), let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown:
            break
        case .leftMouseDown where event.modifierFlags.contains(.control):
            break
        default:
            return nil
        }
        // SwiftUI resolves the context menu of the view under the pointer,
        // so a nested `.contextMenu` inside this row must win over this
        // (topmost) overlay. Deferring lets AppKit's hit-test recursion
        // continue into the content subtree and reach the deeper overlay.
        if deeperOverlayClaims(point) { return nil }
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
        guard isMenuEnabled, !nodes.isEmpty else { return nil }
        let menu = RenderNodeContextMenuBuilder(dispatch: dispatch).makeMenu(nodes: nodes)
        guard menu.items.contains(where: { !$0.isSeparatorItem }) else { return nil }
        return menu
    }

    /// Whether a menu overlay nested in this row's content also contains
    /// `point` (in the superview's coordinate space). The shared superview
    /// hosts exactly this overlay and the row content it covers, so any
    /// other overlay found there belongs to a descendant `.contextMenu`.
    func deeperOverlayClaims(_ point: NSPoint) -> Bool {
        guard let superview else { return false }
        return subtreeContainsClaimingOverlay(superview, excluding: self, point: point, space: superview)
    }
}

/// Depth-first search for another ``RenderNodeContextMenuView`` under `root`
/// whose bounds contain `point` (expressed in `space`'s coordinates) and
/// whose menu IR is non-empty.
@MainActor
private func subtreeContainsClaimingOverlay(
    _ root: NSView,
    excluding excluded: NSView,
    point: NSPoint,
    space: NSView
) -> Bool {
    for subview in root.subviews {
        if subview === excluded || subview.isHidden { continue }
        if let overlay = subview as? RenderNodeContextMenuView {
            let local = overlay.convert(point, from: space)
            if overlay.bounds.contains(local), overlay.isMenuEnabled, !overlay.nodes.isEmpty { return true }
        }
        if subtreeContainsClaimingOverlay(subview, excluding: excluded, point: point, space: space) {
            return true
        }
    }
    return false
}
