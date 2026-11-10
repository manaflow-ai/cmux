#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings

extension DebugMouse {
    /// `debug.mouse {"deliver": "view"}`: the events go to the views as AppKit hands them on in a key window,
    /// not through the event queue. In a no-activate run the window is never key, so AppKit takes a posted
    /// press as the click that makes it key and a view without `acceptsFirstMouse` never sees it (as
    /// `clickPage` notes for Chromium). Each press goes to the view the window's frame view hit-tests under
    /// it, and the drags and the release after it go to that same view, as `NSWindow.sendEvent` routes them.
    /// The press goes through the window's real view tree (overlays, glass, hosting views), so a view that
    /// steals it shows in `delivered_to`. A view that runs its own tracking loop would not get its drags
    /// here; the Home transcript has none. https://github.com/manaflow-ai/cmux/issues/38145.
    static func deliverToViews(_ events: [NSEvent], controller: WindowController, point: NSPoint) -> JSONValue {
        guard let window = controller.window, let frameView = window.contentView?.superview else {
            return .object(["error": .string("no window")])
        }
        var target: NSView?
        var names: [String] = []
        for event in events {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                target = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
                if let target, !names.contains(String(describing: type(of: target))) { names.append(String(describing: type(of: target))) }
            default: break
            }
            guard let target else { continue }
            switch event.type {
            case .leftMouseDown: target.mouseDown(with: event)
            case .leftMouseDragged: target.mouseDragged(with: event)
            case .leftMouseUp: target.mouseUp(with: event)
            case .rightMouseDown: target.rightMouseDown(with: event)
            case .rightMouseUp: target.rightMouseUp(with: event)
            case .otherMouseDown: target.otherMouseDown(with: event)
            case .otherMouseUp: target.otherMouseUp(with: event)
            default: break
            }
        }
        let views: [JSONValue] = names.map { JSONValue.string($0) }
        return .object(["window": .string(controller.state.id), "x": .number(point.x), "y": .number(point.y),
                        "delivered": .number(Double(events.count)),
                        "delivered_to": .array(views)])
    }
}
#endif
