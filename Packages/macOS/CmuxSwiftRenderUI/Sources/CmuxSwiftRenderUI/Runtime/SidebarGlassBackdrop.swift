import AppKit
import SwiftUI

/// The translucent surface behind a glass custom sidebar.
///
/// An in-window SwiftUI Material only blurs whatever the window painted
/// behind the view; over the sidebar's flat backdrop that is visually
/// indistinguishable from a solid color. Behind-window vibrancy is what reads
/// as "glass": the view renders the blurred desktop/windows BEHIND the
/// window into its bounds (the Finder-sidebar treatment), regardless of the
/// opaque layers the host painted underneath.
struct SidebarGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .sidebar
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
