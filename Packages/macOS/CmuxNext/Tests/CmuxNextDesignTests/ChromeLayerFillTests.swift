import AppKit
@testable import CmuxNextDesign
import Testing

/// Chrome-parity p03-rendering-112 (MQ-draw): a popup row's highlight, press fill and focus ring are
/// layer properties set in `updateLayer`, not a `draw(_:)` backing store, so a selection move recolors
/// a layer and repaints no pixels. Chromium paints solid fills as layer colors
/// (cc/layers/solid_color_layer.h) and changes them with Core Animation actions off
/// (ui/base/cocoa/animation_utils.h, `ScopedCAActionDisabler`).
@MainActor @Suite(.serialized) struct ChromeLayerFillTests {
    /// A fill layer starts no implicit animation for any key, even inside an animated transaction.
    @Test func aFillLayerNeverAnimates() {
        let fill = ChromeFillLayer()
        for key in ["backgroundColor", "bounds", "position", "cornerRadius", "borderWidth", "borderColor", "hidden", "onOrderIn"] {
            #expect(fill.action(forKey: key) == nil, "\(key) has no action")
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1)
        fill.backgroundColor = NSColor.red.cgColor
        fill.frame = CGRect(x: 0, y: 0, width: 20, height: 10)
        CATransaction.commit()
        #expect(fill.animationKeys() == nil)
    }

    /// The row updates its layer instead of drawing: no highlight at rest, the hover fill when highlighted,
    /// the focus ring as the fill's border when it has the keys.
    @Test func aPopupRowHighlightsAsALayerProperty() {
        let row = PopupRowView(leading: PopupRowView.checkMark(false), title: "Copy")
        row.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        #expect(row.wantsUpdateLayer)
        #expect(row.layerContentsRedrawPolicy == .onSetNeedsDisplay)
        row.updateLayer()
        #expect(row.highlight.isHidden, "nothing highlights at rest")

        row.needsDisplay = false
        row.isHighlighted = true
        #expect(row.needsDisplay, "the highlight asks for a layer update")
        row.updateLayer()
        #expect(!row.highlight.isHidden)
        #expect(row.highlight.backgroundColor != nil)
        #expect(row.highlight.borderWidth == 0, "no ring without the keys")
        #expect(row.highlight.frame == row.bounds)

        row.takesFocus = true
        _ = row.becomeFirstResponder()
        row.updateLayer()
        #expect(row.highlight.borderWidth > 0, "the focus ring is the fill's border")
        #expect(row.highlight.borderColor != nil)

        _ = row.resignFirstResponder()
        row.isHighlighted = false
        row.updateLayer()
        #expect(row.highlight.isHidden)
    }

    /// The highlight follows a fill inset and a resize of the row.
    @Test func aPopupRowHighlightTakesItsInsetAndFollowsTheSize() {
        var layout = PopupRowView.Layout()
        layout.fillInset = NSSize(width: 4, height: 1)
        let row = PopupRowView(leading: nil, title: "Reload", layout: layout)
        row.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        row.isHighlighted = true
        row.updateLayer()
        #expect(row.highlight.frame == NSRect(x: 4, y: 1, width: 192, height: 22))
        row.setFrameSize(NSSize(width: 300, height: 24))
        #expect(row.highlight.frame == NSRect(x: 4, y: 1, width: 292, height: 22))
    }

    /// A popup's separator is a layer color placed in its middle, inset at each end, and it follows a
    /// resize without a repaint.
    @Test func aPopupSeparatorIsALayerColor() {
        let separator = PopupSeparatorView(frame: NSRect(x: 0, y: 0, width: 200, height: 9))
        #expect(separator.wantsUpdateLayer)
        #expect(separator.layerContentsRedrawPolicy == .onSetNeedsDisplay)
        separator.updateLayer()
        #expect(separator.line.backgroundColor != nil)
        #expect(separator.line.frame == NSRect(x: 6, y: 4, width: 188, height: 1))
        separator.setFrameSize(NSSize(width: 100, height: 9))
        #expect(separator.line.frame == NSRect(x: 6, y: 4, width: 88, height: 1))
    }
}
