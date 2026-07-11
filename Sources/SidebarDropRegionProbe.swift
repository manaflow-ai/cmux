import AppKit
import SwiftUI

/// A transparent, non-interactive NSView that spans the sidebar and registers itself
/// with SidebarDropRegionRegistry while it is in a window. Mounted as a background of
/// the sidebar container, so its frame is the sidebar region and tracks width,
/// visibility and resize automatically.
struct SidebarDropRegionProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                SidebarDropRegionRegistry.register(self)
            } else {
                SidebarDropRegionRegistry.unregister(self)
            }
        }

        // Never intercept clicks or drags; this view exists only to report its frame.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
