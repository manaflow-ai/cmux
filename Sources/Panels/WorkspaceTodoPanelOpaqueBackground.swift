import AppKit
import CmuxSettings
import SwiftUI

struct WorkspaceTodoPanelOpaqueBackground: NSViewRepresentable {
    let color: ChromeColor

    func makeNSView(context: Context) -> NSView {
        let view = WorkspaceTodoPanelOpaqueBackgroundView()
        view.color = color
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WorkspaceTodoPanelOpaqueBackgroundView)?.color = color
        nsView.needsDisplay = true
    }
}
