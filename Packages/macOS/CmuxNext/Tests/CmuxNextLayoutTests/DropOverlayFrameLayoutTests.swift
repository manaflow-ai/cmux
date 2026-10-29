import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// The drop overlay's glass fill, inset card and tab ghost frame their glyph and
/// label from ``ChipLayout`` on every `update`, not by constraints. The overlay's surface resizes every
/// frame of its motion, so before, each frame of a drag solved the content's constraints.
@MainActor @Suite struct DropOverlayFrameLayoutTests {
    static let plane = CGRect(x: 0, y: 0, width: 1200, height: 800)

    static func frame(_ target: CGRect, label: String = "Split Right") -> DropOverlayFrame {
        DropOverlayFrame(target: target, region: target, zone: .right, bounds: plane, cornerRadius: 8, label: label, showsLabel: true)
    }

    static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants(of: $0) } }

    static func label(in view: NSView) throws -> ChromeLabel {
        try #require(descendants(of: view).compactMap { $0 as? ChromeLabel }.first)
    }

    /// The glyph beside `label`: the image view in the same content view.
    static func glyph(beside label: NSView) throws -> NSImageView {
        try #require(label.superview?.subviews.compactMap { $0 as? NSImageView }.first)
    }

    static func alignment(_ view: NSView) -> CGRect { view.alignmentRect(forFrame: view.frame) }

    /// Framed by its owner: no constraint of the content view's holds it.
    static func usesFrames(_ view: NSView) -> Bool {
        view.translatesAutoresizingMaskIntoConstraints
            && (view.superview?.constraints ?? []).allSatisfy { $0.firstItem !== view && $0.secondItem !== view }
    }

    static let long = String(repeating: "Split into a new column ", count: 8)

    @Test func theGlassFillCentersItsLabelAndKeepsItInsideTheGlass() throws {
        _ = NSApplication.shared
        let renderer = GlassFillRenderer(style: .glassFill, material: .opaque)
        renderer.update(Self.frame(CGRect(x: 100, y: 50, width: 600, height: 400)))
        let label = try Self.label(in: renderer.view)
        #expect(!label.isHidden)
        #expect(Self.usesFrames(label))
        let rect = Self.alignment(label)
        #expect(abs(rect.midX - 300) <= 0.5 && abs(rect.midY - 200) <= 0.5, "centered in the 600 x 400 glass")

        renderer.update(Self.frame(CGRect(x: 100, y: 50, width: 120, height: 80), label: Self.long))
        let narrow = Self.alignment(label)
        #expect(narrow.minX >= Metrics.space3 - 0.5)
        #expect(narrow.maxX <= 120 - Metrics.space3 + 0.5, "a long label truncates inside the glass")
    }

    @Test func theInsetCardCentersItsGlyphAndLabelInReadingOrder() throws {
        _ = NSApplication.shared
        let renderer = InsetCardRenderer(material: .opaque)
        let target = CGRect(x: 0, y: 0, width: 600, height: 400)
        renderer.update(Self.frame(target))
        let card = DropOverlayGeometry.insetCard(target: target, fraction: DropOverlayTunables.cardWidthFraction.value,
                                                 maxWidth: DropOverlayTunables.cardMaxWidth.value, height: DropOverlayTunables.cardHeight.value)
        let label = try Self.label(in: renderer.view)
        let glyph = try Self.glyph(beside: label)
        #expect(Self.usesFrames(label) && Self.usesFrames(glyph))
        let text = Self.alignment(label), icon = Self.alignment(glyph)
        #expect(abs(icon.maxX + Metrics.space3 - text.minX) <= 0.5, "the glyph, then the label")
        #expect(abs((icon.minX + text.maxX) / 2 - card.width / 2) <= 1, "the row is centered in the card")
        #expect(abs(text.midY - card.height / 2) <= 0.5 && abs(icon.midY - card.height / 2) <= 0.5)

        renderer.view.userInterfaceLayoutDirection = .rightToLeft
        renderer.update(Self.frame(target, label: Self.long))
        let rtlText = Self.alignment(label), rtlIcon = Self.alignment(glyph)
        #expect(rtlIcon.minX > rtlText.maxX, "right to left, the glyph leads on the right")
        #expect(rtlIcon.maxX <= card.width - Metrics.space4 + 0.5)
        #expect(rtlText.minX >= Metrics.space4 - 0.5, "a long label truncates inside the card's insets")
    }

    @Test func theTabGhostStartsWhereATabsContentStarts() throws {
        _ = NSApplication.shared
        let renderer = TabGhostRenderer(material: .opaque)
        renderer.update(Self.frame(CGRect(x: 0, y: 0, width: 600, height: 400), label: Self.long))
        let label = try Self.label(in: renderer.view)
        let glyph = try Self.glyph(beside: label)
        #expect(Self.usesFrames(label) && Self.usesFrames(glyph))
        // The pill is the ghost's width and a tab's height (the 600 x 400 target fits both).
        let pill = CGSize(width: CGFloat(DropOverlayTunables.ghostWidth.value), height: Metrics.tabHeight)
        #expect(abs(Self.alignment(glyph).minX - Metrics.tabContentLeadingInset) <= 0.5)
        #expect(Self.alignment(label).maxX <= pill.width - Metrics.space4 + 0.5, "a long label truncates inside the pill")
        #expect(abs(Self.alignment(label).midY - pill.height / 2) <= 0.5)
    }

    @Test func aHiddenGlyphGivesTheLabelItsPlace() throws {
        _ = NSApplication.shared
        let renderer = InsetCardRenderer(material: .opaque)
        let label = try Self.label(in: renderer.view)
        let glyph = try Self.glyph(beside: label)
        glyph.isHidden = true
        let views = [glyph, label] as [NSView]
        DropOverlayRenderers.placeRow(views, flexible: label, spacing: 12, insets: ChipLayout.Insets(horizontal: 16, vertical: 0),
                                      in: CGRect(x: 0, y: 0, width: 200, height: 40), centered: false, direction: .leftToRight)
        #expect(abs(Self.alignment(label).minX - 16) <= 0.01, "no room is kept for the hidden glyph")
    }
}
