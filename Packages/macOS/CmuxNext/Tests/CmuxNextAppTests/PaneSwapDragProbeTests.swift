import AppKit
@testable import CmuxNextApp
import CmuxNextLayout
@testable import CmuxNextTabs
import Testing

// TEMPORARY probe (removed before merge): how synthesized events reach a strip's pan recognizer.
@MainActor
struct PaneSwapDragProbeTests {
    @Test func probe() throws {
        let window = PaneSwapDragTests.Window()
        let strip = try #require(window.provider.strips["p1"])
        let recognizer = try #require(strip.gestureRecognizers.first as? NSPanGestureRecognizer)
        let start = try window.emptyStripPoint("p1"), end = try window.center("p2")
        let frame = try #require(window.window.contentView?.superview)
        let hit = frame.hitTest(frame.convert(start, from: nil))
        print("PROBE hit=\(String(describing: hit.map { type(of: $0) })) isStrip=\(hit === strip) visible=\(window.window.isVisible)")
        func ev(_ type: NSEvent.EventType, _ p: CGPoint, _ n: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.window.windowNumber, context: nil, eventNumber: n, clickCount: 1, pressure: 1)!
        }
        window.window.sendEvent(ev(.leftMouseDown, start, 1))
        print("PROBE after down state=\(recognizer.state.rawValue)")
        window.window.sendEvent(ev(.leftMouseDragged, CGPoint(x: start.x + 60, y: start.y), 2))
        print("PROBE after drag1 state=\(recognizer.state.rawValue)")
        window.window.sendEvent(ev(.leftMouseDragged, end, 3))
        print("PROBE after drag2 state=\(recognizer.state.rawValue) swaps=\(window.swaps.count)")
        window.window.sendEvent(ev(.leftMouseUp, end, 4))
        print("PROBE after up state=\(recognizer.state.rawValue) swaps=\(window.swaps.count)")

        let direct = PaneSwapDragTests.Window()
        let s2 = try #require(direct.provider.strips["p1"])
        let r2 = try #require(s2.gestureRecognizers.first as? NSPanGestureRecognizer)
        let a = try direct.emptyStripPoint("p1"), b = try direct.center("p2")
        func ev2(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: direct.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        r2.mouseDown(with: ev2(.leftMouseDown, a))
        r2.mouseDragged(with: ev2(.leftMouseDragged, CGPoint(x: a.x + 60, y: a.y)))
        r2.mouseDragged(with: ev2(.leftMouseDragged, b))
        print("PROBE direct state=\(r2.state.rawValue)")
        r2.mouseUp(with: ev2(.leftMouseUp, b))
        print("PROBE direct after up state=\(r2.state.rawValue) swaps=\(direct.swaps.count)")

        let shown = PaneSwapDragTests.Window()
        shown.window.orderFrontRegardless()
        shown.drag(from: try shown.emptyStripPoint("p1"), to: try shown.center("p2"))
        print("PROBE ordered-front swaps=\(shown.swaps.count) visible=\(shown.window.isVisible)")
        shown.window.orderOut(nil)
    }
}
