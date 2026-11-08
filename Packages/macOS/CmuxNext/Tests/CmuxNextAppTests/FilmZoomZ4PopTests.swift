#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// ZOOM VARIANTS 3 (fork only, never merged): the Z4 zoom in showed the old unzoomed layout for 1-3 frames about 5
/// frames after it landed (films zv-v-c3-nvim-z4-k6-in frame 55, k12-in frame 65, on 92d84262, a59e55cd-pin and
/// 478c8175). The live fade's end put each covered pane back at full opacity in its own transaction and retired
/// (hid) it only after that, so a frame could show it at opacity 1 over the zoomed pane. No covered pane may reach
/// full opacity while it still shows.
@MainActor
@Suite(.closesItsWindows)
struct FilmZoomZ4PopTests {
    @MainActor final class Seen { var shownAtFull: [String] = [] }

    @Test func theFadeEndNeverShowsACoveredPaneAtFullOpacity() throws {
        let film = DesignSettings.shared.filmZoom
        defer { DesignSettings.shared.filmZoom = film }
        _ = FilmZoomVariant.select("zoom_variant Z4 K6")
        let screen = ZoomKeepsCoveredPanesTests.Screen()
        defer { screen.window.closeAfterTest() }
        let covered: [PaneID] = ["p2", "p3", "p4"]
        let hosts = try covered.map { try #require(screen.root.context.hosts[$0]) }

        screen.show(.leaf("p1"), zoomed: true)
        _ = screen.root.advanceFrame(1.0 / 120) // the presentation starts the live fade
        try #require(!screen.screen.frameInput.filmZoomFading.isEmpty, "Z4 zoom in fades its covered panes live")

        let seen = Seen()
        let watches = hosts.compactMap { host in
            host.layer?.observe(\.opacity, options: [.new]) { _, change in
                MainActor.assumeIsolated { // main-proof: the fade's end sets the opacity on the main thread
                    if change.newValue == 1, !host.isHidden { seen.shownAtFull.append(host.pane.rawValue) }
                }
            }
        }
        defer { watches.forEach { $0.invalidate() } }
        screen.screen.stopFilmFade(retiring: true) // what the fade's completion runs

        let shown = hosts.filter { !$0.isHidden }.map(\.pane.rawValue)
        let dimmed = hosts.filter { $0.layer?.opacity != 1 }.map(\.pane.rawValue)
        #expect(seen.shownAtFull.isEmpty, "covered panes back at opacity 1 while still shown: \(seen.shownAtFull)")
        #expect(shown.isEmpty, "the fade's end retires (hides) every covered pane: \(shown) still shown")
        #expect(dimmed.isEmpty, "a retired pane keeps full opacity for the unzoom: \(dimmed) not at 1")
    }
}
#endif
