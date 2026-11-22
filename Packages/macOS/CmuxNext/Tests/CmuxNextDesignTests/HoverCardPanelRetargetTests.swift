import AppKit
import Testing
@testable import CmuxNextDesign

/// R131: a retarget moves the visible card to the next tab in the same
/// frame (Chrome); no window-frame slide that trails the pointer.
@MainActor
@Suite(.serialized)
struct HoverCardPanelRetargetTests {
    @Test func aRetargetMovesTheCardInTheSameFrame() throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        parent.isReleasedWhenClosed = false
        let panel = HoverCardPanel()
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        body.widthAnchor.constraint(equalToConstant: 200).isActive = true
        body.heightAnchor.constraint(equalToConstant: 80).isActive = true
        panel.present(body: body, anchor: CGRect(x: 200, y: 400, width: 100, height: 30), placement: .below, parent: parent,
                      themeAnchor: nil, sliding: false, applyTheme: {})
        panel.present(body: body, anchor: CGRect(x: 420, y: 400, width: 100, height: 30), placement: .below, parent: parent,
                      themeAnchor: nil, sliding: true, applyTheme: {})
        #expect(panel.frame.minX == 420, "the card is at the new tab now, not sliding there")
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
