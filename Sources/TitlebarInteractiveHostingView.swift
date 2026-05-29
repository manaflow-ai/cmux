import AppKit
import SwiftUI

/// Hosts SwiftUI controls that must receive titlebar mouse-downs instead of moving the window.
@MainActor
final class TitlebarInteractiveHostingView<Content: View>: NSHostingView<Content> {
    nonisolated static var viewIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("cmux.titlebarInteractiveControl")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
