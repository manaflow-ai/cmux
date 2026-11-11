import AppKit
@testable import CmuxNextApp
import Testing

/// Leo 2026-11-11, on the notifications panel: "there's no close button :(". The header ends in a ×
/// that closes the panel, beside Mark All Read and Clear All.
@MainActor
@Suite(.serialized) struct NotificationsPanelCloseTests {
    @Test func headerCloseButtonClosesThePanel() throws {
        let card = NotificationsPanelView()
        var closed = 0
        card.onClose = { closed += 1 }
        let close = try #require(Self.button(in: card, id: "cmux.notifications.close"), "the panel's header has no ×")
        #expect(close.accessibilityLabel() == NotificationsPanelStrings.close)
        close.performClick(nil)
        #expect(closed == 1)
    }

    private static func button(in view: NSView, id: String) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == id { return button }
        for subview in view.subviews {
            if let found = button(in: subview, id: id) { return found }
        }
        return nil
    }
}
