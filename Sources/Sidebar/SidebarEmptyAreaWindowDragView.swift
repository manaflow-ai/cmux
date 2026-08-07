import SwiftUI

/// Hosts the compact sidebar's native empty-area drag target in SwiftUI.
struct SidebarEmptyAreaWindowDragView: NSViewRepresentable {
    /// Creates the AppKit hit target used by the compact sidebar empty area.
    func makeNSView(context: Context) -> SidebarEmptyAreaWindowDragNSView {
        SidebarEmptyAreaWindowDragNSView()
    }

    /// The hit target has no SwiftUI state to synchronize after creation.
    func updateNSView(_ nsView: SidebarEmptyAreaWindowDragNSView, context: Context) {}
}
