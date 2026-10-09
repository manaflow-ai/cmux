import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextApp

/// The icon picker is a popup (#18729 natively): the shared radius and the
/// card's one 12% shadow instead of a 12 pt radius and the window shadow,
/// with the picker's page at its full size inside the card.
@MainActor @Suite struct IconPickerPopupTests {
    @Test func thePickerIsAPopup() throws {
        let page = NSView()
        let panel = IconPickerPanel(content: page, size: NSSize(width: 300, height: 200))
        let host = try #require(panel.contentView as? PopupHostView)
        #expect(!panel.hasShadow)
        #expect(host.card.layer?.cornerRadius == PopupStyle.cornerRadius)
        #expect(host.shadowLayer.shadowOpacity == Float(PopupStyle.shadowAlpha))
        host.layoutSubtreeIfNeeded()
        #expect(page.frame.size == NSSize(width: 300, height: 200))
        #expect(panel.frame.size == NSSize(width: 300 + 2 * PopupStyle.shadowMargin, height: 200 + 2 * PopupStyle.shadowMargin))
        // The masked material keeps its corners; the host's layer casts the shadow around them.
        #expect(host.shadowLayer.shadowPath?.boundingBox == host.card.frame)
    }
}
