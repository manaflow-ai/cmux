import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The real notes card, presented beside the sidebar's update card as the sidebar shows it, on a
/// display (`HoverCardBandHoverTests` has the bug): its clear band covers the update card's top
/// right corner, where the x is, and passes the pointer there; the drawn card does not.
@Suite(.serialized, .closesItsWindows)
@MainActor struct HoverCardBandPanelTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    @Test(.enabled("the card's window is placed on a screen") { await Self.hasDisplay() })
    func theNotesCardsBandPassesThePointerOverTheUpdateCardsX() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first).visibleFrame
        let parent = NSWindow(contentRect: NSRect(x: screen.minX + 100, y: screen.minY + 100, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        let panel = HoverCardPanel()
        defer {
            panel.closeAfterTest()
            parent.closeAfterTest()
        }
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.widthAnchor.constraint(equalToConstant: 300), body.heightAnchor.constraint(equalToConstant: 200)])
        // The update card at the sidebar's bottom.
        let updateCard = CGRect(x: parent.frame.minX + 12, y: parent.frame.minY + 60, width: 260, height: 48)
        panel.present(body: body, anchor: updateCard, placement: .beside, parent: parent, themeAnchor: nil, sliding: false,
                      interactive: true, applyTheme: {})
        let card = panel.presentedCardFrame
        // The update card's top right corner, where its x is: inside the notes window's frame, outside its card.
        let corner = NSPoint(x: updateCard.maxX - 8, y: updateCard.maxY - 8)
        #expect(panel.frame.contains(corner), "the premise: the notes window's band covers the update card's x (\(panel.frame) vs \(corner))")
        #expect(!card.contains(corner))
        #expect(panel.passesPointer(atScreen: corner), "the band hid the update card's x from its hover")
        #expect(!panel.passesPointer(atScreen: NSPoint(x: card.midX, y: card.midY)), "the card itself covers")
        #expect(panel.bandRelay != nil, "an interactive card relays band moves to its parent's hover")

        // The window server's own answer at the corner: when it names the notes window (the bug's
        // premise on this display), the hover's answer looks through it.
        let raw = NSWindow.windowNumber(at: corner, belowWindowWithWindowNumber: 0)
        let seen = PointerTopWindow.number(at: corner)
        #expect(seen != panel.windowNumber, "window server: \(raw), hover: \(seen), notes card: \(panel.windowNumber)")
        if raw == panel.windowNumber {
            #expect(seen == NSWindow.windowNumber(at: corner, belowWindowWithWindowNumber: panel.windowNumber))
        }
    }
}
