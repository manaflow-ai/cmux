import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSidebar
import Testing

    /// Lawrence 2026-10-23: "i cant X this out anymore even when hovering on it". The x was the
    /// page's own button; WebKit shows no hover and eats the first click while another of the
    /// app's windows (a Chromium page's) has the key. The host's native x shows on the pointer's
    /// entry, takes a first click in a window that is not key, and sends `.dismissUpdated`.
    @Test func theNativeXShowsOnHoverTakesTheFirstClickAndDismisses() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let model = SidebarModel(sections: [])
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.updateSurfaces = UpdateSurfaceIslands(services: services)
        let host = sidebar.updatedCardView
        host.configure(SidebarUpdatedCard(title: "Updated", whatsNewTitle: "See What's New", dismissLabel: "Close"))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
        host.layoutSubtreeIfNeeded()

        #expect(!host.closeShown, "the x waits for the pointer")
        host.setHovered(true)
        #expect(host.closeShown, "the pointer on the card shows the x")
        #expect(host.closeButton.accessibilityLabel() == "Close")
        #expect(host.closeButton.frame.maxX == 200 - host.closeInset, "the x sits at the card's top right")
        #expect(host.subviews.last === host.closeButton, "the page never covers the x")
        // Leo 2026-11-07: the card wears the composer's material, which its page paints (no native veil
        // of its own under the page any more).
        #expect(!host.subviews.contains { $0 is CardSurfaceView }, "a native veil under the page doubles the composer's glass")
        #expect(host.closeButton.acceptsFirstMouse(for: nil), "a first click in a window that is not key presses the x")

        host.closeButton.performClick(nil)
        #expect(intents == [.dismissUpdated], "the x goes through the sidebar's one card-dismiss path")

        host.configure(nil)
        #expect(!host.closeShown, "a card that comes back waits for the pointer again")
    }
}
