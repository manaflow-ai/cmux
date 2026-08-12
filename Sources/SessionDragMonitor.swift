import SwiftUI

/// SwiftUI bridge for the AppKit monitor that initiates native Vault drags.
struct SessionDragMonitor: NSViewRepresentable {
    let regions: SessionDragRegionStore
    let beginDrag: SessionDragBeginAction

    func makeNSView(context: Context) -> SessionDragMonitorView {
        SessionDragMonitorView(regions: regions, beginDrag: beginDrag)
    }

    func updateNSView(_ nsView: SessionDragMonitorView, context: Context) {
        nsView.regions = regions
        nsView.beginDrag = beginDrag
    }
}
