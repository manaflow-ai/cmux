import AppKit
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// `sidebar.noFade` (Lawrence 2026-10-26): the sidebar's edges stop fading and the bottom profile and
/// search bar hides, so the whole list shows. Cmd+Shift+P's "Show Whole Sidebar (No Fade)" turns it
/// on and "Restore Sidebar Fade" turns it off; both write cmux.json, as the band-hide commands do.
@MainActor @Suite(.serialized) struct SidebarNoFadeTests {
    @Test func theSidebarFadesAndShowsItsProfileBarByDefault() async throws {
        let h = try await SidebarBandHideTests().make()
        defer { h.tearDown() }
        #expect(h.sidebar.edgeFade.fades)
        #expect(h.sidebar.aboveFade.fades)
        #expect(h.sidebar.belowFade.fades)
        #expect(!h.sidebar.footerRegion.isHidden)
        #expect(!h.sidebar.searchButton.isHidden)
    }

    @Test func noFadeStopsEveryEdgeFadeAndHidesTheProfileAndSearchBar() async throws {
        let h = try await SidebarBandHideTests().make(#"{"sidebar":{"noFade":true}}"#)
        defer { h.tearDown() }
        #expect(!h.sidebar.edgeFade.fades)
        #expect(!h.sidebar.aboveFade.fades)
        #expect(!h.sidebar.belowFade.fades)
        #expect(h.sidebar.footerRegion.isHidden)
        #expect(h.sidebar.searchButton.isHidden)
        #expect(h.sidebar.profileBar.isHidden)
    }

    @Test func thePaletteCommandsTurnNoFadeOnAndBackOff() async throws {
        let h = try await SidebarBandHideTests().make()
        defer { h.tearDown() }
        _ = h.services.registry.perform("sidebar.noFade.on")
        await h.until { !h.sidebar.edgeFade.fades && h.sidebar.searchButton.isHidden && h.saved("noFade") == true }
        #expect(!h.sidebar.edgeFade.fades)
        #expect(h.sidebar.searchButton.isHidden)
        #expect(h.saved("noFade") == true)

        _ = h.services.registry.perform("sidebar.noFade.off")
        await h.until { h.sidebar.edgeFade.fades && !h.sidebar.searchButton.isHidden && h.saved("noFade") == false }
        #expect(h.sidebar.edgeFade.fades)
        #expect(!h.sidebar.searchButton.isHidden)
        #expect(h.saved("noFade") == false)
    }
}
