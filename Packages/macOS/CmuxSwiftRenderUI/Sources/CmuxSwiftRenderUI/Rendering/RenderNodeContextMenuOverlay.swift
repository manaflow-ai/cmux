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

    func makeNSView(context: Context) -> RenderNodeContextMenuView {
        let view = RenderNodeContextMenuView()
        view.nodes = nodes
        view.dispatch = dispatch
        return view
    }

    func updateNSView(_ nsView: RenderNodeContextMenuView, context: Context) {
        nsView.nodes = nodes
        nsView.dispatch = dispatch
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

    private func present(with event: NSEvent) {
        guard !nodes.isEmpty else { return }
        let menu = RenderNodeMenuBuilder.menu(for: nodes, dispatch: dispatch)
        guard menu.items.contains(where: { !$0.isSeparatorItem }) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
