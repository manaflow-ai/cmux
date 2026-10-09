import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// The group editor bubble is a popup (#18729 natively): the shared radius
/// and the card's one 12% shadow, never the system window shadow.
@MainActor @Suite struct SidebarGroupEditorPopupTests {
    @Test func theEditorIsAPopup() throws {
        let panel = SidebarGroupEditorPanel()
        let host = try #require(panel.contentView as? PopupHostView)
        let card = try #require(host.card as? OverlaySurfaceView)
        #expect(!panel.hasShadow)
        #expect(card.cornerRadius == PopupStyle.cornerRadius)
        #expect(card.shadow?.shadowBlurRadius == PopupStyle.shadowBlur)
    }
}
