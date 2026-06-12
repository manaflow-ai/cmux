import AppKit
import SwiftUI

final class TitlebarAccessoryContainerView: NSView {
    fileprivate static func shouldResolveWindowDragHit(eventType: NSEvent.EventType?) -> Bool {
        eventType == nil || eventType == .leftMouseDown
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard Self.shouldResolveWindowDragHit(eventType: NSApp.currentEvent?.type) else {
            return super.hitTest(point)
        }
        return super.hitTest(point) ?? self
    }
}

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

/// Protects an interactive control hosted in (or over) the window titlebar from
/// window-management gestures — window drag, resize drag, and the double-click
/// zoom/minimize action — while leaving the control fully clickable.
///
/// The control stays in its existing SwiftUI host; the modifier only registers
/// the control's region with ``MinimalModeTitlebarControlHitRegionRegistry`` via
/// a transparent `.background(...)` marker (``TitlebarInteractiveControlRegion``).
/// Titlebar drag/double-click routing consults that registry and yields over the
/// region, so the control keeps receiving mouse-downs in place.
struct TitlebarInteractiveControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(TitlebarInteractiveControlRegion())
    }
}

extension View {
    func titlebarInteractiveControl() -> some View {
        modifier(TitlebarInteractiveControlModifier())
    }
}
