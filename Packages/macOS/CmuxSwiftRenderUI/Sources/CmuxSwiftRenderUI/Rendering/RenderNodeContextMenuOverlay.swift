import AppKit
import CmuxSwiftRender
import SwiftUI

/// A transparent overlay that presents an interpreted `.contextMenu` as a
/// native `NSMenu` built on demand at right-click (or control-click) time.
///
/// This replaces SwiftUI's `.contextMenu` hosting for interpreted sidebars:
/// on macOS that modifier eagerly rebuilds menu content on every view update
/// and leaks `ObservationTracking` unboundedly
/// (https://github.com/manaflow-ai/cmux/issues/7345). The overlay holds only
/// the pure-data menu IR; nothing menu-related is built during rendering.
struct RenderNodeContextMenuOverlay: NSViewRepresentable {
    let nodes: [RenderNode]
    let dispatch: SidebarActionDispatch
    /// VoiceOver bridge: the row's `.accessibilityAction(.showMenu)` presents
    /// through this handle, which tracks the mounted overlay view.
    let handle: RenderNodeContextMenuHandle

    func makeNSView(context: Context) -> RenderNodeContextMenuView {
        let view = RenderNodeContextMenuView()
        view.nodes = nodes
        view.dispatch = dispatch
        handle.view = view
        return view
    }

    func updateNSView(_ nsView: RenderNodeContextMenuView, context: Context) {
        nsView.nodes = nodes
        nsView.dispatch = dispatch
        handle.view = nsView
    }
}

/// Connects a row's SwiftUI `.accessibilityAction(.showMenu)` (the VoiceOver
/// path a native `.contextMenu` provides, VO-Shift-M) to the mounted overlay
/// view, so accessibility users keep interpreted context menus. Weak so the
/// handle never extends the platform view's lifetime.
@MainActor
final class RenderNodeContextMenuHandle {
    weak var view: RenderNodeContextMenuView?

    /// Presents the menu anchored to the overlay's row bounds (no mouse
    /// event exists on the accessibility path).
    func presentMenu() {
        view?.presentFromAccessibility()
    }
}

/// Backing `NSView` for ``RenderNodeContextMenuOverlay`` that hit-tests only
/// context-menu clicks (right-click, control-click), letting left-click
/// taps and drags pass through to the SwiftUI row underneath — the same
/// event-filtered `hitTest` idiom as `MiddleClickCaptureView`.
final class RenderNodeContextMenuView: NSView {
    var nodes: [RenderNode] = []
    var dispatch: SidebarActionDispatch = .noop

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown:
            return self
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return self
        default:
            return nil
        }
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

    /// The on-demand menu, or nil when the IR yields nothing presentable
    /// (no nodes, or separators only).
    func menuForPresentation() -> NSMenu? {
        guard !nodes.isEmpty else { return nil }
        let menu = RenderNodeMenuBuilder.menu(for: nodes, dispatch: dispatch)
        guard menu.items.contains(where: { !$0.isSeparatorItem }) else { return nil }
        return menu
    }
}
