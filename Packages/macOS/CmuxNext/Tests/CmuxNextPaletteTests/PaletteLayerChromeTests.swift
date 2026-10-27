import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import Testing

/// Chrome-parity p03-rendering-112 (MQ-draw): the palette's keycaps, footer chips and Actions menu
/// rows paint fills as layer properties in `updateLayer` (and glyphs as ``ChromeTextLayer``s), never a
/// `draw(_:)` backing store, so a selection move or a theme change recolors layers and repaints no
/// pixels (cc/layers/solid_color_layer.h).
@MainActor @Suite(.serialized) struct PaletteLayerChromeTests {
    private static func fills(_ view: NSView) -> [ChromeFillLayer] {
        view.layer?.sublayers?.compactMap { $0 as? ChromeFillLayer } ?? []
    }

    /// One fill layer per cap, each with its glyph layer, placed left to right and colored in updateLayer.
    @Test func keycapsAreLayersPlacedAndColored() throws {
        let caps = PaletteKeycapsView()
        #expect(caps.wantsUpdateLayer)
        caps.keycaps = ["⌘", "K"]
        let size = caps.intrinsicContentSize
        caps.frame = NSRect(origin: .zero, size: size)
        caps.layout()
        caps.updateLayer()
        let fills = Self.fills(caps)
        #expect(fills.count == 2)
        #expect(fills.allSatisfy { $0.backgroundColor != nil })
        #expect(fills.allSatisfy { ($0.sublayers?.first as? ChromeTextLayer) != nil })
        let texts = fills.compactMap { $0.sublayers?.first as? ChromeTextLayer }
        #expect(texts.map(\.string) == ["⌘", "K"])
        #expect(texts.allSatisfy { $0.foregroundColor != nil })
        let first = try #require(fills.first), last = try #require(fills.last)
        #expect(first.frame.minX == 0)
        #expect(last.frame.minX > first.frame.maxX, "the second cap sits after the first")
        #expect(abs(last.frame.maxX - size.width) < 0.5, "the caps fill the measured width")
        #expect(caps.layer?.contents == nil, "the view draws no backing store")
    }

    /// A type-scale change (Interface Size, the chrome font size) reaches the same caps' glyphs: the next
    /// layout and update put them in the font `layout()` measures with, not the font they were made in.
    @Test func theSameKeycapsTakeANewFontSize() throws {
        let saved = DesignSettings.shared.overrides[.chromeFontSize]
        defer { DesignSettings.shared.setOverride(.chromeFontSize, saved) }
        DesignSettings.shared.setOverride(.chromeFontSize, nil)
        let caps = PaletteKeycapsView()
        caps.keycaps = ["⌘", "K"]
        caps.frame = NSRect(origin: .zero, size: caps.intrinsicContentSize)
        caps.layout()
        caps.updateLayer()
        let before = Typography.shortcut
        DesignSettings.shared.setOverride(.chromeFontSize, 16)
        let after = Typography.shortcut
        try #require(after.pointSize != before.pointSize, "the override changes the shortcut size")
        caps.frame = NSRect(origin: .zero, size: caps.intrinsicContentSize)
        caps.layout()
        caps.updateLayer()
        let texts = Self.fills(caps).compactMap { $0.sublayers?.first as? ChromeTextLayer }
        #expect(texts.count == 2)
        #expect(texts.allSatisfy { $0.font == after }, "the glyphs draw in the font the frames measure with")
    }

    /// The same caps again keep their layers; new caps replace them.
    @Test func theSameKeycapsKeepTheirLayers() {
        let caps = PaletteKeycapsView()
        caps.keycaps = ["⌘", "W"]
        let before = Self.fills(caps).map(ObjectIdentifier.init)
        caps.keycaps = ["⌘", "W"]
        #expect(Self.fills(caps).map(ObjectIdentifier.init) == before)
        caps.keycaps = ["↩"]
        #expect(Self.fills(caps).count == 1)
    }

    /// A selected Actions menu row fills its own layer in the row radius; an unselected one is clear.
    @Test func aSelectedMenuRowFillsItsLayer() {
        let command = PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform {})
        let selected = PaletteMenuRow(command: command, keycaps: ["↩"], isSelected: true)
        let plain = PaletteMenuRow(command: command, keycaps: nil, isSelected: false)
        #expect(selected.wantsUpdateLayer)
        selected.updateLayer()
        plain.updateLayer()
        #expect(selected.layer?.backgroundColor != nil)
        #expect(selected.layer?.cornerRadius == PaletteLayout.rowCornerRadius)
        #expect(plain.layer?.backgroundColor == nil)
    }

    /// A footer chip's pill is its layer's color in half its height.
    @Test func aClickViewFillsAPillLayer() {
        let chip = PaletteClickView()
        chip.frame = NSRect(x: 0, y: 0, width: 60, height: 20)
        chip.updateLayer()
        #expect(chip.layer?.backgroundColor == nil)
        chip.needsDisplay = false
        chip.fillsBackground = true
        #expect(chip.needsDisplay)
        chip.updateLayer()
        #expect(chip.layer?.backgroundColor != nil)
        #expect(chip.layer?.cornerRadius == 10)
        chip.setFrameSize(NSSize(width: 60, height: 24))
        #expect(chip.layer?.cornerRadius == 12)
    }
}
