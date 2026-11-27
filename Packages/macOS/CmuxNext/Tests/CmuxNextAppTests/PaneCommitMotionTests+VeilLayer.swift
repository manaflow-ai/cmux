import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxTheme
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the layer that the rows read as a pane's veil.
///
/// A pane's overlay has one layer for each thing that it draws. The veil is the one that fills the pane: the only
/// layer of the overlay that gets a fill (a background color), from the overlay's first update on. Each other layer
/// draws a line or a shadow and gets no fill: the border, the focus ring, its flash and the attention ring stroke a
/// border; the ring's glow is a shadow in a layer that clips; the theme's glow is a shadow under a mask; the rim is a
/// gradient under a mask. So the rows find the veil by its fill and not by its place: a theme's glow goes in under
/// each other layer of the overlay.
extension PaneCommitMotionTests {
    /// The layer of the veil of `overlay` (the overlay of `name`): the one layer of the overlay that has a fill.
    /// With no such layer (an overlay that got no update has none), or with more than one, the row gets a set-up
    /// issue and no layer.
    static func veilLayer(of overlay: PaneOverlayView, _ name: String = "a pane",
                          sourceLocation: SourceLocation = #_sourceLocation) -> CALayer? {
        let fills = (overlay.layer?.sublayers ?? []).filter { $0.backgroundColor != nil }
        guard fills.count == 1 else {
            Issue.record("SETUP: \(fills.count) layers of the overlay of \(name) have a fill: the veil is the one layer that has one",
                         sourceLocation: sourceLocation)
            return nil
        }
        return fills[0]
    }

    /// The layer of the veil of `host`: the veil's layer of its overlay, with the same set-up issue.
    static func veilLayer(of host: PaneHostView, sourceLocation: SourceLocation = #_sourceLocation) -> CALayer? {
        veilLayer(of: host.chrome, "\(host.pane)", sourceLocation: sourceLocation)
    }

    /// An overlay of a pane that has not the focus, with a veil and with a glow of the theme, each given to the
    /// overlay's own update: the glow's layer is the lowest layer of the overlay and shows nothing, and the layer
    /// that the rows read is the veil with its strength, not the glow's layer.
    @Test func withAThemesGlowUnderItTheRowsStillReadTheVeil() throws {
        _ = NSApplication.shared
        let overlay = PaneOverlayView()
        overlay.setFrameSize(NSSize(width: 400, height: 300))
        let color = ThemeRGB(red: 0.5, green: 0.5, blue: 0.5)
        overlay.update(showsRing: false, dim: 0.3, focusRing: FocusRingSettings(),
                       accentGlow: ThemeFlourishes.Glow(dark: color, light: color, radius: 8, opacity: 0.5),
                       border: PaneOverlayView.Border(shows: false), attention: nil, attentionSettings: AttentionSettings(),
                       focused: false, animated: false)
        let glow = try #require(overlay.accentGlowLayer, "SETUP: an update with a glow made no layer for the glow")
        try #require(overlay.layer?.sublayers?.first === glow, "SETUP: the glow's layer is not the lowest layer of the overlay")
        try #require(glow.opacity == 0 && abs(overlay.dimOpacity - 0.3) < 0.001,
                     "SETUP: the glow's layer has the opacity \(glow.opacity) and the veil \(overlay.dimOpacity): not 0 and 0.3")
        let veil = try #require(Self.veilLayer(of: overlay), "the overlay with a glow has no layer that the rows read as its veil")
        #expect(veil !== glow, "with a glow under the veil the rows read the glow's layer as the veil")
        #expect(abs(veil.opacity - 0.3) < 0.001 && veil.frame == overlay.dimFrame,
                "the layer that the rows read has the opacity \(veil.opacity) and the frame \(veil.frame): the veil has 0.3 and \(overlay.dimFrame)")
    }
}
