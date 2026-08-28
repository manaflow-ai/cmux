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
