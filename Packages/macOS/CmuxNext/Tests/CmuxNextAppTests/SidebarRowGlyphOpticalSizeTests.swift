import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-09 (screenshot 6:55 PM): "the cmux app icon on 'cmux-next landing' looks smaller than the other
/// icons, and the gap between the icon and the title is too wide; the GitHub logo on 'SR2 route move' and the browser
/// globe are different sizes". Each glyph was fitted by its image square, so a favicon with a transparent margin (an
/// app icon) drew its ink smaller than a full-bleed mark or a symbol, and the title, placed after the square, sat
/// further from that smaller ink.
///
/// The contract, at every density: every row's leading glyph (a margined favicon, a symbol, Home's house, a pin) draws
/// its ink at one optical size along its larger side, and the gap from the end of that ink to its title is one gap.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRowGlyphOpticalSizeTests {
    typealias Case = HomePinnedRowAlignmentTests.Case
    nonisolated static let cases: [Case] = SidebarDensity.allCases.map { Case(density: $0, minimal: .off, width: 260) }
    /// Ink is measured on a 2x bitmap: half a point, plus a pixel for antialiasing at the edges.
    static let tolerance: CGFloat = 1

    /// The drawn ink box of `view` and its subviews, in `view`'s coordinates (top-left origin), from a 2x bitmap:
    /// pixels at least a quarter opaque. Nil when it draws nothing.
    static func inkBox(_ view: NSView) throws -> CGRect? {
        view.subviews.forEach { $0.layoutSubtreeIfNeeded() }
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.25 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: CGFloat(minX) / 2, y: CGFloat(minY) / 2, width: CGFloat(maxX - minX + 1) / 2, height: CGFloat(maxY - minY + 1) / 2)
    }

    /// Each glyph's ink in list points and the x its title starts at.
    static func glyphs(_ list: SidebarListView) throws -> [(name: String, ink: CGRect, titleX: CGFloat)] {
        var out: [(String, CGRect, CGFloat)] = []
        let home = try HomePinnedRowAlignmentTests.item(list, SidebarLeadingEdgeTests.home.id)
        out.append(("Home's house", list.convert(try #require(home.glyphInkFrame, "Home drew no glyph"), from: home),
                    SidebarLeadingEdgeTests.x(list, home.titleFrame.minX, in: home)))
        for (name, id) in [("a margined favicon (an app icon)", SidebarLeadingEdgeTests.web), ("a symbol (the globe's kind)", SidebarLeadingEdgeTests.symbol)] {
            let row = try HomePinnedRowAlignmentTests.row(list, id)
            let ink = try #require(try inkBox(row.icon), "\(name) drew nothing")
            out.append((name, list.convert(ink, from: row.icon), SidebarLeadingEdgeTests.x(list, row.title.frame.minX, in: row)))
        }
        return out
    }

    @Test(arguments: cases, DensityPreset.allCases)
    func everyRowGlyphHasOneOpticalSize(_ c: Case, preset: DensityPreset) throws {
        try HomePinnedRowAlignmentTests.at(c, preset: preset) {
            let (list, window) = SidebarLeadingEdgeTests.list(width: c.width)
            defer { window.close() }
            for g in try Self.glyphs(list) {
                // A favicon takes its tab's size, a pack glyph the glyphs' (#49583: "the same size as the horizontal tabs").
                let size = g.name.contains("favicon") ? SidebarStyle.rowFaviconOpticalSide : SidebarStyle.rowGlyphOpticalSide
                let longest = SidebarOpticalGlyph.fittedExtent(g.ink.size)
                #expect(abs(longest - size) <= Self.tolerance,
                        "\(c.testDescription): \(g.name)'s ink is \(g.ink.width) x \(g.ink.height), the rows' optical size is \(size)")
            }
        }
    }

    @Test(arguments: cases, DensityPreset.allCases)
    func everyGlyphKeepsOneGapBeforeItsTitle(_ c: Case, preset: DensityPreset) throws {
        try HomePinnedRowAlignmentTests.at(c, preset: preset) {
            let (list, window) = SidebarLeadingEdgeTests.list(width: c.width)
            defer { window.close() }
            // The pin is a narrow mark (its ink about a third as wide as tall): its title starts on the one text column with
            // the others, so the room after its slender ink is wider by design. The gap holds for the glyphs that fill
            // the column's width: Home's house, a favicon, a symbol.
            let glyphs = try Self.glyphs(list).filter { $0.name != "a pin" }
            // A glyph wider than tall (Home's house at the rows' glyph height) spills evenly past its column: measure its
            // gap from the column's end, its ink's end less that spill.
            // A favicon fills its tab's larger side from the same leading edge (#49583), so it ends that much nearer its
            // title: measure its gap from the end of the glyphs' square, as the others'.
            let side = SidebarStyle.rowGlyphOpticalSide, faviconGrowth = SidebarStyle.rowFaviconOpticalSide - side
            let gaps = glyphs.map { g -> (String, CGFloat) in
                let own = g.name.contains("favicon") ? SidebarStyle.rowFaviconOpticalSide : side
                return (g.name, g.titleX - (g.ink.maxX - max(0, (g.ink.width - own) / 2)) + (g.name.contains("favicon") ? faviconGrowth : 0))
            }
            let first = try #require(gaps.first).1
            // Each glyph's frame snaps its origin and its size to whole pixels (`SidebarOpticalGlyph`, a crisp bitmap), up
            // to half a 1x pixel each, so two glyphs' gaps can differ by up to one pixel more than the contract's point.
            for (name, gap) in gaps {
                #expect(abs(gap - first) <= Self.tolerance + 0.5, "\(c.testDescription): \(name) is \(gap) pt from its title, Home's house \(first)")
            }
        }
    }

    /// A tuned glyph size (`sidebarRows.glyphSize`) wins over a density's icon box: the glyphs fill the tuned side at
    /// Default, Comfortable and Spacious too (Codex review).
    @Test(arguments: [DensityPreset.cozy, .comfortable, .spacious])
    func aTunedGlyphSizeWinsOverTheIconBox(preset: DensityPreset) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        #expect(SidebarStyle.rowGlyphOptics.box != nil, "\(preset): the density draws its rows at the tab's box")
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([SidebarRowTuning.glyphSize.descriptor])
        let key = SidebarRowTuning.glyphSize.tunable.key
        let savedOverride = TunableStore.shared.override(key)
        #expect(TunableStore.shared.set(key, .number(22)) == .number(22))
        defer { TunableStore.shared.set(key, savedOverride) }
        let optics = SidebarStyle.rowGlyphOptics
        #expect(optics.box == nil, "\(preset): a tuned glyph size still draws at the box \(String(describing: optics.box))")
        #expect(optics.target == 22, "\(preset): the glyphs fill \(optics.target), not the tuned 22")
    }
}
