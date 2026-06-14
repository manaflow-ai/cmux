import AppKit
import SwiftUI

final class TitlebarAccessoryHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard TitlebarAccessoryContainerView.shouldResolveWindowDragHit(eventType: NSApp.currentEvent?.type) else {
            return super.hitTest(point)
        }
        guard let window else { return nil }

        let locationInWindow = convert(point, to: nil)
        guard isMinimalModeTitlebarControlHit(window: window, locationInWindow: locationInWindow) else {
            return nil
        }
        return super.hitTest(point) ?? self
    }
}

typealias NonDraggableHostingView<Content: View> = TitlebarAccessoryHostingView<Content>
