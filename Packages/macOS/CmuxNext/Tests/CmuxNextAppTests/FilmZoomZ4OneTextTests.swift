#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// ZOOM VARIANTS 6 (fork only, never merged): the Z4 zoom out showed the nvim pane's text twice for 4-6 frames (film
/// C3 zoom out, /work/tmp/zv5-sheets/c3-out-sheet.png): the zoomed pane's old full picture faded out on the shrink's
/// progress over the live pane, which shows the new wrap, so two text layouts showed through each other. A terminal shows
/// one picture: the old one, opaque, then the live pane, switched in one refresh with no fade.
@MainActor
@Suite(.closesItsWindows)
struct FilmZoomZ4OneTextTests {
    /// The zoomed pane's terminal surface: its frame at the new size lands when the test says so.
    final class Landing: NSView, FilmFrameLanding {
        var filmFrameLanded: (@MainActor () -> Void)?
    }

    /// Whether `layer` shows at an opacity between 0 and 1 now or at any point of an opacity animation on it.
    static func fades(_ layer: CALayer) -> Bool {
        if layer.opacity > 0, layer.opacity < 1 { return true }
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) as? CAPropertyAnimation, animation.keyPath == "opacity" else { continue }
            var values: [Any] = []
            if let frames = animation as? CAKeyframeAnimation { values = frames.values ?? [] }
            if let basic = animation as? CABasicAnimation { values = [basic.fromValue, basic.toValue].compactMap { $0 } }
            if values.contains(where: { (($0 as? NSNumber)?.floatValue).map { $0 > 0 && $0 < 1 } ?? false }) { return true }
        }
        return false
    }

    @Test func theZoomOutShowsOnePictureAndSwapsWhenTheNewFrameLands() throws {
        let film = DesignSettings.shared.filmZoom
        defer { DesignSettings.shared.filmZoom = film }
        _ = FilmZoomVariant.select("zoom_variant Z4 K6")
        let screen = ZoomKeepsCoveredPanesTests.Screen()
        defer { screen.window.closeAfterTest() }
        let zoomed = try #require(screen.root.context.hosts["p1"])
        zoomed.content.wantsLayer = true
        zoomed.content.layer?.backgroundColor = CGColor(gray: 0.1, alpha: 1) // the pane's ground (a terminal's background)
        let surface = Landing(frame: zoomed.content.bounds)
        zoomed.content.addSubview(surface)
        screen.show(.leaf("p1"), zoomed: true)
        screen.land()

        screen.show(ZoomKeepsCoveredPanesTests.four, zoomed: false)
        _ = screen.root.advanceFrame(1.0 / 120)
        let container = try #require(screen.screen.layer?.sublayers?.first { $0.name?.hasPrefix("film-zoom-pictures-") == true },
                                     "Z4 zoom out shows the zoomed pane's old picture")
        let picture = try #require(container.sublayers?.first)
        let live = try #require(zoomed.layer)

        // Before the frame at the new grid lands: the old picture only, opaque, over the live pane.
        #expect(!container.isHidden && !picture.isHidden, "the old picture shows until the new frame lands")
        #expect(!Self.fades(container) && !Self.fades(picture),
                "the old picture fades over the live pane: two text layouts show through each other")
        #expect(!Self.fades(live), "the live zoomed pane fades")

        // The zoomed terminal's frame at its new size lands (3-4 refreshes in): nothing swaps yet (ZOOM VARIANTS 7: a swap
        // here showed the live pane at its final size while the frame was far from its place, FilmZoomZ4CurveTests). The
        // old picture goes later in one refresh, with no value between: never a fade between the two pictures.
        let landed = surface.filmFrameLanded // what the presenter's pass calls (it clears it first)
        surface.filmFrameLanded = nil
        landed?()
        #expect(!picture.isHidden && !container.isHidden, "the old picture went at the landing, before the frame reached its place")
        #expect(!Self.fades(container) && !Self.fades(picture) && !Self.fades(live), "a fade between two pictures after the landing")
    }
}
#endif
