#if DEBUG
import AppKit
import CmuxNextAgentPane
import CmuxNextSettings
import CmuxNextTabs

/// A transient capture overlay. It never enters the page store, daemon tabs, history or
/// window records: removing it reveals the presentation that stayed attached underneath.
@MainActor
struct DebugNativeRowToolsFixture {
    /// `debug.native_row_tools_fixture {tools?, menu?, width?, window?, inspect?, dismiss?}`.
    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let window = DebugWindowSnapshot.window(params.merging(["kind": .string("main")]) { current, _ in current }, services: services) else {
            return .object(["error": .string("no window")])
        }
        return run(params, in: window)
    }

    /// The RPC's entire mutation path takes only a window, never persistence services.
    static func run(_ params: [String: JSONValue], in window: NSWindow) -> JSONValue {
        guard let content = window.contentView else { return .object(["error": .string("no content view")]) }
        let previous = content.subviews.compactMap { $0 as? DebugNativeRowToolsFixtureView }.first
        if params["dismiss"]?.boolValue == true {
            previous?.removeFromSuperview()
            return .object(["ok": .bool(true)])
        }
        if params["inspect"]?.boolValue == true {
            guard let previous else { return .object(["error": .string("no fixture")]) }
            return geometry(previous, in: window)
        }
        let sample = DebugNativeRowToolsSample()
        guard let tools = sample.decode(params["tools"] ?? sample.tools) else {
            previous?.removeFromSuperview()
            return .object(["error": .string("unsupported pane.tabRowTools.set: invalid tools")])
        }
        let width = params["width"]?.doubleValue ?? 760
        guard width.isFinite, (1...2000).contains(width) else {
            previous?.removeFromSuperview()
            return .object(["error": .string("width must be between 1 and 2000 points")])
        }
        let fixture = previous ?? DebugNativeRowToolsFixtureView(frame: content.bounds)
        if fixture.superview == nil {
            fixture.autoresizingMask = [.width, .height]
            content.addSubview(fixture, positioned: .above, relativeTo: nil)
        }
        fixture.configure(tools: tools, width: width)
        content.layoutSubtreeIfNeeded()
        if let menu = params["menu"]?.stringValue, !fixture.openMenu(menu) {
            fixture.removeFromSuperview()
            return .object(["error": .string("no visible enabled menu tool: \(menu)")])
        }
        return .object(["ok": .bool(true), "tools": .array(tools.map { .string($0.id) })])
    }

    private static func geometry(_ fixture: DebugNativeRowToolsFixtureView, in window: NSWindow) -> JSONValue {
        guard let bounds = fixture.snapshotBounds() else {
            return .object(["error": .string("fixture or menu extends outside the captured window")])
        }
        let rect = bounds.capture
        return .object([
            "ok": .bool(true), "menuVisible": .bool(bounds.menuVisible),
            "capture": .object(["x": .number(rect.minX), "y": .number(rect.minY),
                                "width": .number(rect.width), "height": .number(rect.height)]),
            "window": .object(["width": .number(window.frame.width), "height": .number(window.frame.height)]),
            "scale": .number(window.backingScaleFactor),
        ])
    }
}
#endif
