#if DEBUG
import AppKit
import CmuxNextSettings

/// `debug.layers` `layout_loop_fixture`: "open" shows a small window
/// whose one view asks for layout from inside its own layout, the feedback loop
/// AppKit ends the app over ("more Layout Window passes than there are views in
/// the window"); "close" removes it. The layout-loop stress run opens it to prove
/// a loop is reported without ending the app (cx-3j8y).
enum DebugLayoutLoop {
    private static var window: NSWindow?

    /// The fixture's state after `value` ("open", or "closed" with how many
    /// times the looping view was laid out), or nil for no or an unknown value.
    static func handle(_ value: String?) -> JSONValue? {
        switch value {
        case "open":
            open()
            return .string("open")
        case "close":
            window?.orderOut(nil)
            window = nil
            return .object(["state": .string("closed"), "layouts": .number(Double(LayoutLoopFixtureView.layouts))])
        default:
            return nil
        }
    }

    private static func open() {
        guard window == nil else { return }
        LayoutLoopFixtureView.layouts = 0
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 200, height: 120)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        // Enough views that AppKit's limit (a pass per view) is past the guard's.
        for index in 0..<24 { host.addSubview(NSView(frame: NSRect(x: 100 + index * 4, y: 10, width: 2, height: 2))) }
        let looping = LayoutLoopFixtureView()
        looping.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(looping)
        NSLayoutConstraint.activate([looping.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 10),
                                     looping.topAnchor.constraint(equalTo: host.topAnchor, constant: 10)])
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
    }
}

/// The cx-wcej loop by construction: its natural height depends on its own
/// frame (as a truncating label's did), so every layout changes the height
/// the next one solves for.
final class LayoutLoopFixtureView: NSView {
    static var layouts = 0

    override var intrinsicContentSize: NSSize { NSSize(width: 80, height: frame.height == 40 ? 41 : 40) }

    override func layout() {
        super.layout()
        Self.layouts += 1
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}
#endif
