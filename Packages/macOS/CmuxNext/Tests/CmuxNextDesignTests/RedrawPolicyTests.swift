import AppKit
@testable import CmuxNextDesign
import Testing

/// A view that paints in `updateLayer` redraws only when it asks to
/// (`.onSetNeedsDisplay`), not on every frame of a resize (AppKit's `.duringViewResize`); a container
/// with nothing to draw never redraws. Chromium's compositor does the same: a geometry change moves
/// and clips a layer, and only contents marked invalid repaint (cc/layers/layer.cc, SetNeedsDisplayRect).
@MainActor @Suite struct RedrawPolicyTests {
    @Test func layerPaintingViewsRedrawOnlyWhenAsked() {
        let views: [(String, NSView)] = [
            ("ChromeLabel", ChromeLabel(labelWithString: "Label")),
            ("HairlineView", HairlineView(frame: .zero)),
            ("CardSurfaceView", CardSurfaceView()),
            ("OverflowButton", OverflowButton(label: "More")),
            ("StatusIndicatorView", StatusIndicatorView(frame: .zero)),
            ("LaunchMarkView", LaunchMarkView(frame: .zero)),
            ("OverlayScrimView", OverlayScrimView(frame: .zero)),
        ]
        for (name, view) in views {
            #expect(view.layerContentsRedrawPolicy == .onSetNeedsDisplay, "\(name) redraws on \(view.layerContentsRedrawPolicy.rawValue)")
        }
        #expect(OverlayClipView(frame: .zero).layerContentsRedrawPolicy == .never)
    }

    /// The label's glyph image has the old size's ink: a size change marks it for display itself
    /// (its glyphs keep their pixel size until then, never stretched), and a same-size set does not.
    @Test func aLabelRedrawsOnASizeChangeOnly() {
        let label = ChromeLabel(labelWithString: "Label")
        label.setFrameSize(NSSize(width: 80, height: 16))
        label.needsDisplay = false
        label.setFrameSize(NSSize(width: 80, height: 16))
        #expect(!label.needsDisplay, "a same-size set redraws the label")
        label.setFrameSize(NSSize(width: 120, height: 16))
        #expect(label.needsDisplay, "a size change leaves the old glyph image")
    }
}
