public import SwiftUI

extension View {
    /// The app's themed tooltip for a SwiftUI view (instead of `.help`, which draws AppKit's).
    /// An empty `text` shows none.
    public func themedHelp(_ text: String, shortcut: String? = nil) -> some View {
        background(ThemedHelpAnchor(text: text, shortcut: shortcut))
    }
}

/// A view-sized AppKit view behind the SwiftUI view that carries its `themedToolTip`.
private struct ThemedHelpAnchor: NSViewRepresentable {
    var text: String
    var shortcut: String?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        update(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { update(view) }

    private func update(_ view: NSView) {
        if view.themedToolTipShortcut != shortcut { view.themedToolTipShortcut = shortcut }
        if view.themedToolTip != (text.isEmpty ? nil : text) { view.themedToolTip = text }
    }
}
