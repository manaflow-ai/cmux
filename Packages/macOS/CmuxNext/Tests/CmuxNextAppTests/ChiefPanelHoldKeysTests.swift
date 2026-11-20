import AppKit
import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// The Chief panel holds one Chief view. When the view it holds changes (Home's first Chief tab
/// is another view after a daemon delta), the old one goes back to Home instead of staying covered
/// in the panel: covered, it kept the keys, and typing went into a box no one could see
/// (plans/cmux-next/focus-loss-AUDIT.md, cause C3).
@MainActor @Suite(.serialized, .closesItsWindows) struct ChiefPanelHoldKeysTests {
    private static func chief() -> (view: NSView, field: NSTextField) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 22))
        view.addSubview(field)
        return (view, field)
    }

    @Test func aNewChiefViewTakesTheKeysTheCoveredOneHad() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = try #require(window.contentView)
        let panel = ChiefPanelView(title: "Chief", actions: .init(toggleDock: {}, hide: {}, moved: { _ in }))
        panel.frame = host.bounds
        panel.mount(in: host)
        let old = Self.chief(), new = Self.chief()
        panel.hold(old.view)
        #expect(window.makeFirstResponder(old.field))
        panel.hold(new.view)
        #expect(old.view.superview == nil, "nothing stays covered in the panel")
        let responder = try #require(window.firstResponder as? NSView)
        #expect(!responder.isDescendant(of: old.view), "no covered view keeps the keys")
        #expect(responder.isDescendant(of: new.view), "the shown Chief has them")
    }
}
