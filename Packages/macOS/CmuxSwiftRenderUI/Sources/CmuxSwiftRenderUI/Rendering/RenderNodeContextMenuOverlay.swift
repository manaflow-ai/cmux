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
    /// Logical render-tree location of the row owning this overlay. SwiftUI
    /// can flatten nested platform views, so this path supplies ownership
    /// information that AppKit's view ancestry does not retain.
    let contextMenuPath: [Int]
    /// VoiceOver bridge: the row's `.accessibilityAction(.showMenu)` presents
    /// through this handle, which tracks the mounted overlay view.
    let handle: RenderNodeContextMenuHandle

    func makeNSView(context: Context) -> RenderNodeContextMenuView {
        let view = RenderNodeContextMenuView()
        apply(to: view, context: context)
        return view
    }

    func updateNSView(_ nsView: RenderNodeContextMenuView, context: Context) {
        apply(to: nsView, context: context)
    }

    private func apply(to view: RenderNodeContextMenuView, context: Context) {
        view.nodes = nodes
        view.dispatch = dispatch
        view.contextMenuPath = contextMenuPath
        // `.disabled(true)` on the row or an ancestor reaches the overlay as
        // the SwiftUI `isEnabled` environment; a disabled row must not offer
        // its context menu, matching native SwiftUI behavior.
        view.isMenuEnabled = context.environment.isEnabled
        handle.view = view
    }
}
