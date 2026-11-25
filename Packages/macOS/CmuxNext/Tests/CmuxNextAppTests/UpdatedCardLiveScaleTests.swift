import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import Testing

/// The Updated card's frame is its page's CSS height times the page zoom. A live `app.uiScale` change
/// zooms the page without a new size report (the CSS height stays), so the island takes the last report
/// again at the new zoom: a 48 px card at 1.25 is 60 points, not the 48 it was at 1.0 (DEV readback).
@MainActor
@Suite(.serialized)
struct UpdatedCardLiveScaleTests {
    @Test func aLiveScaleChangeResizesTheCardWithoutANewReport() async throws {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let saved = design.uiScale
        design.uiScale = 1
        defer { design.uiScale = saved }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let island = UpdateSurfaceIsland(kind: .updated, services: services)
        defer { island.close() }
        var relayouts = 0
        island.onHeightChange = { relayouts += 1 }
        island.provider.onSize?(48, 0, 120, 0)
        #expect(island.contentHeight == 48)
        #expect(island.overlayHeight == 120)

        design.uiScale = 1.25
        // The page follows the setting through its observation: give it a few turns.
        for _ in 0..<100 where island.contentHeight != 60 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(island.contentHeight == 60, "the card kept \(island.contentHeight) points at 125%")
        #expect(island.overlayHeight == 150, "the preview's room kept \(island.overlayHeight) points at 125%")
        #expect(relayouts == 2, "the sidebar was not told to lay the card out again")
    }
}
