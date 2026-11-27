import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// With the sidebar hidden, the pointer over the top-left corner, the traffic lights and the sidebar toggle's slot
/// where the open band would be, opens the 0-wide toolbar band (cx-fi0i, Lawrence 2026-10-09); Back and Forward's
/// slots do not, and once open the whole top row keeps it open (Leo 2026-11-27: "should only be around the sidebar
/// toggle + maybe its constituent padding? including the back AND the forward button is a bit big...").
@Suite(.closesItsWindows)
@MainActor struct CornerHoverBandTests {
    /// A window root in a titled, full-size-content window, as the app shows it, sidebar hidden.
    func collapsedRoot() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.presentation = .hidden
        let root = WindowRootView(sidebar: SidebarContainerView(model: model))
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        root.sidebar.isHidden = true
        root.sidebarHidden = true
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    @Test func thePointerOverTheToggleSlotOpensItAndTheTopRowKeepsItOpen() throws {
        let (window, root) = CollapsedTitlebarZoneGalleryTests.offscreenCollapsedRoot()
        defer { window.close() }
        #expect(root.toolbarBand.frame.width == 0)
        let rest = root.titlebarRevealRegion.frame
        let top = rest.midY
        let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
        #expect(rest.contains(CGPoint(x: root.convert(lights, from: nil).maxX + 1, y: top)))
        // The rest of the strip does not reveal.
        #expect(!rest.contains(CGPoint(x: root.bounds.midX, y: top)))

        let forward = try CollapsedTitlebarZoneGalleryTests.openForwardFrame(root)
        #expect(root.collapsedBand.isOpen)
        #expect(root.titlebarReveal.isRevealed)
        // Revealed, the zone is the whole top row: the pointer anywhere in the tab bar keeps the buttons.
        let open = root.titlebarRevealRegion.frame
        #expect(open.minY == rest.minY && open.height == rest.height)
        #expect(open.width == root.bounds.width)
        #expect(open.contains(CGPoint(x: root.bounds.midX, y: top)))
        #expect(open.contains(CGPoint(x: forward.maxX + 40, y: top)))
    }

    /// At rest the zone ends at the open sidebar toggle's slot (the toggle plus its padding): Back and Forward do not
    /// reveal (Leo 2026-11-27). The zone is never drawn, so it ends exactly at the slot, not a pixel-aligned edge.
    @Test func theRestingZoneEndsAtTheToggleSlot() throws {
        let (window, root) = CollapsedTitlebarZoneGalleryTests.offscreenCollapsedRoot()
        defer { window.close() }
        let zone = root.titlebarRevealRegion.frame
        _ = try CollapsedTitlebarZoneGalleryTests.openForwardFrame(root)
        let band = root.toolbarBand
        let toggle = root.convert(band.sidebarToggle.bounds, from: band.sidebarToggle)
        let back = root.convert(band.backButton.bounds, from: band.backButton)
        let forward = root.convert(band.forwardButton.bounds, from: band.forwardButton)
        #expect(abs(zone.maxX - toggle.maxX) < 0.5)
        #expect(zone.contains(CGPoint(x: toggle.midX, y: toggle.midY)))
        #expect(!zone.contains(CGPoint(x: back.midX, y: back.midY)))
        #expect(!zone.contains(CGPoint(x: forward.midX, y: forward.midY)))
    }

    /// The pointer leaving the top row lets the band close and the zone shrink back to the toggle slot.
    @Test func leavingTheTopRowShrinksTheZone() throws {
        let (window, root) = CollapsedTitlebarZoneGalleryTests.offscreenCollapsedRoot()
        defer { window.close() }
        let rest = root.titlebarRevealRegion.frame
        _ = try CollapsedTitlebarZoneGalleryTests.openForwardFrame(root)
        #expect(root.titlebarRevealRegion.frame.width == root.bounds.width)
        root.titlebarReveal.setPointerInside(false)
        root.layoutSubtreeIfNeeded()
        // Still open through the close delay: the zone stays the whole row, so a return to the tab bar keeps it.
        if root.collapsedBand.isOpen {
            #expect(root.titlebarRevealRegion.frame.width == root.bounds.width)
        } else {
            #expect(root.titlebarRevealRegion.frame == rest)
        }
    }
}
