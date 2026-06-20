import AppKit
import SwiftUI

struct WorkspaceSidebarKeyboardFocusBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceSidebarKeyboardFocusView {
        WorkspaceSidebarKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ nsView: WorkspaceSidebarKeyboardFocusView, context: Context) {
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}
