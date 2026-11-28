public import SwiftUI

extension View {
    /// The app's themed tooltip for a SwiftUI view (instead of `.help`, which draws AppKit's), and
    /// its accessibility hint, as `.help` gives. An empty `text` adds nothing.
    @ViewBuilder
    public func themedHelp(_ text: String, shortcut: String? = nil) -> some View {
        if text.isEmpty {
            self
        } else {
            background(ThemedHelpAnchor(text: text, shortcut: shortcut)).accessibilityHint(Text(text))
        }
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
