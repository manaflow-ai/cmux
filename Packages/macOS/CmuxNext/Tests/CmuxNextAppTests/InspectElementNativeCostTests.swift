import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Inspect Element inspects web content only. While its picker runs, an event over native
/// AppKit/SwiftUI views must go on untouched: no hit-test, no highlight overlay, no swallowed
/// click. The suite also times the picker's cost per mouse move over a deep native view tree
/// (`INSPECT-BENCH` lines in the log), the main-thread work every move paid before.
@MainActor @Suite(.serialized, .closesItsWindows) struct InspectElementNativeCostTests {
    /// A window whose content is `depth` nested views, each level with `siblings` neighbours
    /// that a hit-test scans first; returns the window and the deepest view's centre (screen).
    private func deepNativeWindow(depth: Int = 40, siblings: Int = 12) -> (NSWindow, NSPoint) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var parent: NSView = window.contentView!
        for _ in 0..<depth {
            let inset = parent.bounds.insetBy(dx: 4, dy: 4)
            for index in 0..<siblings {
                parent.addSubview(NSView(frame: NSRect(x: inset.minX + CGFloat(index), y: inset.minY, width: 1, height: 1)))
            }
            let child = NSView(frame: inset)
            parent.addSubview(child, positioned: .below, relativeTo: nil)
            parent = child
        }
        let centre = parent.convert(NSPoint(x: parent.bounds.midX, y: parent.bounds.midY), to: nil)
        return (window, window.convertPoint(toScreen: centre))
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func viewCount(_ view: NSView?) -> Int {
        guard let view else { return 0 }
        return 1 + view.subviews.reduce(0) { $0 + viewCount($1) }
    }

    @Test func thePickerLeavesNativeViewsAloneAndCostsNothingPerMove() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.pointerInspector.descriptor])
        TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, .bool(true))
        defer { TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, nil) }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let inspector = UIInspectorController(services: services)
        let (window, point) = deepNativeWindow()
        defer { window.close() }
        let frameView = window.contentView?.superview
        let viewsBefore = viewCount(frameView), childWindowsBefore = window.childWindows?.count ?? 0

        inspector.toggle()
        #expect(inspector.isPicking)
        defer { if inspector.isPicking { inspector.toggle() } }
        let move = mouse(.mouseMoved, at: point, in: window)
        #expect(inspector.handle(move, window: window, point: point) === move)

        let moves = 5_000
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<moves { _ = inspector.handle(move, window: window, point: point) }
        }
        let nanos = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
        print(String(format: "INSPECT-BENCH native mouseMoved while picking: %d moves, %.2f us/move, %.1f ms total",
                     moves, nanos / Double(moves) / 1000, nanos / 1e6))

        // Nothing drawn over native UI: no highlight view, no overlay window.
        #expect(viewCount(frameView) == viewsBefore, "a highlight was added over a native view")
        #expect((window.childWindows?.count ?? 0) == childWindowsBefore, "an overlay window was added over a native view")
        // A click on a native view reaches it: the picker never swallows it to select the view.
        let click = mouse(.leftMouseDown, at: point, in: window)
        #expect(inspector.handle(click, window: window, point: point) === click, "the picker swallowed a native click")
        inspector.toggle()
        #expect(!inspector.isPicking)
    }
}
