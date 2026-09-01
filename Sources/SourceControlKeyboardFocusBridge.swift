import AppKit
import SwiftUI

/// Embeds the Source Control AppKit focus endpoint in its SwiftUI hierarchy.
struct SourceControlKeyboardFocusBridge: NSViewRepresentable {
    let focusFirstItem: @MainActor () -> Bool

    init(focusFirstItem: @escaping @MainActor () -> Bool = { false }) {
        self.focusFirstItem = focusFirstItem
    }

    func makeNSView(context: Context) -> SourceControlKeyboardFocusView {
        let view = SourceControlKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.focusFirstItemAction = focusFirstItem
        return view
    }

    func updateNSView(_ nsView: SourceControlKeyboardFocusView, context: Context) {
        nsView.focusFirstItemAction = focusFirstItem
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}
