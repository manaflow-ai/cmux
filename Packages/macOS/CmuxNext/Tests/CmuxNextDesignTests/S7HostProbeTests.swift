import AppKit
import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// A diagnostic, not a test to land (branch cp/fix-tip-swift-s7-ui-probe): prints what the fleet's test host
/// gives the S7 suites (a GUI session, screens, window-server windows) and how AppKit keeps `needsDisplay`, so
/// each S7 failure can be judged product or test. Every line starts with "S7PROBE".
@MainActor @Suite(.serialized)
struct S7HostProbeTests {
    private func say(_ line: String) { print("S7PROBE \(line)") }

    @Test func hostFacts() {
        _ = NSApplication.shared
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        say("session=\(session.map { _ in "yes" } ?? "nil") onConsole=\(session?[kCGSessionOnConsoleKey as String] ?? "-") loginDone=\(session?[kCGSessionLoginDoneKey as String] ?? "-")")
        say("screens=\(NSScreen.screens.count) main=\(NSScreen.main.map { "\($0.frame)" } ?? "nil") activation=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive)")
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let listed = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .contains { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        say("window number=\(window.windowNumber) visible=\(window.isVisible) onScreenList=\(listed) occlusion=\(window.occlusionState.rawValue) screen=\(window.screen != nil)")
        say("NSApp.window(withWindowNumber:) found=\(NSApp.window(withWindowNumber: window.windowNumber) === window)")
        window.makeKeyAndOrderFront(nil)
        say("key after makeKey: \(window.isKeyWindow) NSApp.keyWindow=\(NSApp.keyWindow === window)")
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        window.contentView?.addSubview(view)
        say("makeFirstResponder(view)=\(window.makeFirstResponder(view)) firstResponder is view=\(window.firstResponder === view)")
        if let cg = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: 300, y: 300), mouseButton: .left) {
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            say("NSEvent(cgEvent:).window is window=\(NSEvent(cgEvent: cg)?.window === window)")
        }
    }

    private func report(_ name: String, _ view: NSView) {
        view.needsDisplay = false
        let cleared = view.needsDisplay
        view.needsDisplay = true
        say("\(name): after false=\(cleared) after true=\(view.needsDisplay) layer=\(view.layer != nil) policy=\(view.layerContentsRedrawPolicy.rawValue) window=\(view.window != nil)")
    }

    @Test func needsDisplayFacts() {
        _ = NSApplication.shared
        let plain = NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        report("plain", plain)
        let layered = NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20)); layered.wantsLayer = true
        report("layered", layered)
        let onSet = NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20)); onSet.wantsLayer = true
        onSet.layerContentsRedrawPolicy = .onSetNeedsDisplay
        report("layered+onSetNeedsDisplay", onSet)
        report("ChromeLabel", ChromeLabel(labelWithString: "Label"))
        report("CardSurfaceView", CardSurfaceView())
        report("PopupRowView", PopupRowView(leading: PopupRowView.checkMark(false), title: "Copy"))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100)); window.contentView = host
        let label = ChromeLabel(labelWithString: "Label"); host.addSubview(label)
        report("ChromeLabel in window", label)
        let card = CardSurfaceView(); host.addSubview(card)
        report("CardSurfaceView in window", card)
        let label2 = ChromeLabel(labelWithString: "Label")
        label2.setFrameSize(NSSize(width: 80, height: 16)); label2.needsDisplay = false
        label2.setFrameSize(NSSize(width: 120, height: 16))
        say("ChromeLabel size change (no window): needsDisplay=\(label2.needsDisplay) layerNeedsDisplay=\(label2.layer?.needsDisplay() ?? false)")
    }
}
