import SwiftUI
import AppKit

/// NSViewRepresentable that hosts a CEFBrowserView in SwiftUI.
struct CEFBrowserViewRepresentable: NSViewRepresentable {
    let cefBrowserView: CEFBrowserView

    func makeNSView(context: Context) -> CEFBrowserView {
        cefBrowserView
    }

    func updateNSView(_ nsView: CEFBrowserView, context: Context) {
        // Layout is handled by autoresizing masks and CEFBrowserView.layout()
    }
}
