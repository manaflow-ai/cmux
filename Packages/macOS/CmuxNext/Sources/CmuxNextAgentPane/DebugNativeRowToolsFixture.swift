#if DEBUG
public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings

/// A transient capture overlay. It never enters the page store, daemon tabs, history or
/// window records: removing it reveals the presentation that stayed attached underneath.
/// The app passes the overlay type (CmuxNextTabs' DebugNativeRowToolsFixtureView) and the window.
@MainActor
public struct DebugNativeRowToolsFixture<Overlay: DebugNativeRowToolsOverlay> {
    private let sample = DebugNativeRowToolsSample()

    /// A fixture that shows `Overlay`.
    public init(overlay _: Overlay.Type) {}

    /// `debug.native_row_tools_fixture {tools?, menu?, width?, window?, inspect?, dismiss?}` in the
    /// window the app resolved from `params` (the main window by default); nil answers "no window".
    public func show(_ params: [String: JSONValue], in window: NSWindow?) -> JSONValue {
        guard let window else { return .object(["error": .string("no window")]) }
        return run(params, in: window)
    }

    /// The RPC's entire mutation path takes only a window, never persistence services.
    public func run(_ params: [String: JSONValue], in window: NSWindow) -> JSONValue {
        guard let content = window.contentView else { return .object(["error": .string("no content view")]) }
        let previous = content.subviews.compactMap { $0 as? Overlay }.first
        if params["dismiss"]?.boolValue == true {
            previous?.removeFromSuperview()
            return .object(["ok": .bool(true)])
        }
        if params["inspect"]?.boolValue == true {
            guard let previous else { return .object(["error": .string("no fixture")]) }
            return geometry(previous, in: window)
        }
        guard let tools = sample.decode(params["tools"] ?? sample.tools) else {
            previous?.removeFromSuperview()
            return .object(["error": .string("unsupported pane.tabRowTools.set: invalid tools")])
        }
        let width = params["width"]?.doubleValue ?? 760
        guard width.isFinite, (1...2000).contains(width) else {
            previous?.removeFromSuperview()
            return .object(["error": .string("width must be between 1 and 2000 points")])
        }
        let fixture = previous ?? Overlay(frame: content.bounds)
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

    private func geometry(_ fixture: Overlay, in window: NSWindow) -> JSONValue {
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
