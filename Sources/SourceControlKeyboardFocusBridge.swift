import AppKit
import SwiftUI

/// Embeds the Source Control AppKit focus endpoint in its SwiftUI hierarchy.
struct SourceControlKeyboardFocusBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> SourceControlKeyboardFocusView {
        SourceControlKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ nsView: SourceControlKeyboardFocusView, context: Context) {
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}
