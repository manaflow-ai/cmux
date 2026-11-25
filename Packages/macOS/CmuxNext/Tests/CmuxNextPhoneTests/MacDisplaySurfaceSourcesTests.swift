@testable import CmuxNextPhone
import Testing

/// hostd's `surface` tabs `d~<display>` are this Mac's displays (cmux-mobile-host `mac_display_of`
/// takes the same keys), and the app's grant (Share This Mac on) decides each start.
@MainActor
struct MacDisplaySurfaceSourcesTests {
    @Test func aDisplayTabNamesOneDisplayOnce() {
        #expect(MacDisplaySurfaceSources.display(of: "d~0") == 0)
        #expect(MacDisplaySurfaceSources.display(of: "d~69734272") == 69_734_272)
        #expect(MacDisplaySurfaceSources.display(of: "d~4294967295") == UInt32.max)
        for tab in ["", "d", "d~", "d~01", "d~-1", "d~+1", "d~ 1", "d~1 ", "d~4294967296", "D~1", "d1", "s1", "c~m~t", "d~١"] {
            #expect(MacDisplaySurfaceSources.display(of: tab) == nil, "\(tab)")
        }
        #expect(MacDisplaySurfaceSources.tab(display: 7) == "d~7")
        #expect(CloudDesktopSurfaceSources.target(of: "d~1") == nil)
    }

    @Test func aRefusedGrantStartsNoSource() async {
        let sources = MacDisplaySurfaceSources { _ in throw MacDisplaySurfaceSources.Failure.notShared }
        await #expect(throws: MacDisplaySurfaceSources.Failure.notShared) {
            _ = try await sources.start(tab: "d~0", onExit: {})
        }
        await #expect(throws: MacDisplaySurfaceSources.Failure.notMacDisplay) {
            _ = try await sources.start(tab: "s12", onExit: {})
        }
        #expect(sources.runningTabs.isEmpty)
    }

    @Test func sharingAlreadyOffStartsNoCapture() async {
        var fed = false
        let sources = MacDisplaySurfaceSources { display in
            .init(feed: SurfaceFrameFeed(start: { _, _ in fed = true }, stop: {}), label: "display \(display)", stillLive: { false })
        }
        await #expect(throws: MacDisplaySurfaceSources.Failure.notShared) {
            _ = try await sources.start(tab: "d~0", onExit: {})
        }
        #expect(!fed)
        #expect(sources.runningTabs.isEmpty)
    }
}
