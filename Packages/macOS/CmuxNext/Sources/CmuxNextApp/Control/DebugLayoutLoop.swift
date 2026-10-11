#if DEBUG
import AppKit
import CmuxNextSettings

/// `debug.layers` `layout_loop_fixture`: "open" shows a small off-screen window
/// whose one view asks for layout from inside its own layout, the feedback loop
/// AppKit ends the app over ("more Layout Window passes than there are views in
/// the window"); "close" removes it. The layout-loop stress run opens it to prove
/// a loop is reported without ending the app (cx-3j8y).
enum DebugLayoutLoop {
    private static var window: NSWindow?

    /// The fixture's state after `value`, or nil for no or an unknown value.
    static func handle(_ value: String?) -> JSONValue? {
        switch value {
        case "open":
            open()
            return .string("open")
        case "close":
            window?.orderOut(nil)
            window = nil
            return .string("closed")
        default:
            return nil
        }
    }

    private static func open() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        host.addSubview(LayoutLoopFixtureView(frame: NSRect(x: 10, y: 10, width: 80, height: 40)))
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
    }
}

/// Asks for another layout from inside every layout: a loop by construction.
final class LayoutLoopFixtureView: NSView {
    override func layout() {
        super.layout()
        needsLayout = true
    }
}
#endif
