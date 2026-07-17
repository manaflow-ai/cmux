import AppKit
import SwiftUI

@available(macOS 15.4, *)
struct BrowserWebExtensionAnchorViewReader: NSViewRepresentable {
    let holder: BrowserWebExtensionAnchorViewHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}
