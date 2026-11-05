import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Testing

/// Leo 2026-11-05: "Why is it just one solid opaque block? Why does it not have any sort of rim at all?", "still
/// keeping the colors, it's just, like, but just make it glassier", and "this strange f***ing font of the group on the
/// side". A band header is a translucent pane of its color raised in chroma, with a hairline rim, its name in the theme's
/// ink at the rows' own size, semibold; the solid bar stays a Debug choice. The palette is unchanged.
@MainActor @Suite(.serialized) struct GroupHeaderGlassTests {
    static func withGlass(_ glass: SidebarGroupGlass, _ body: () throws -> Void) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarGroupGlass.tunable.key
        defer { TunableStore.shared.set(key, nil) }
        try #require(TunableStore.shared.set(key, glass.tunableValue) == glass.tunableValue)
        try body()
    }

    @Test(arguments: [SidebarGroupGlass.glass, .vivid, .frost])
    func aGlassHeaderIsATranslucentPaneWithARim(_ glass: SidebarGroupGlass) throws {
        try Self.withGlass(glass) {
            for (name, scope) in try GroupPaletteDefaultTests.themes() {
                let (sidebar, ids) = try GroupPaletteDefaultTests.sidebar(GroupPaletteDefaultTests.order)
                scope.root(sidebar)
                sidebar.layoutSubtreeIfNeeded()
                for id in ids {
                    let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
                    header.layoutSubtreeIfNeeded()
                    header.updateLayer()
                    let fill = try #require(header.pill.backgroundColor.flatMap(NSColor.init(cgColor:)))
                    #expect(fill.alphaComponent > 0.05 && fill.alphaComponent < 0.6, "\(glass) \(name): the pane is \(fill.alphaComponent) opaque")
                    #expect(header.pill.borderWidth > 0, "\(glass) \(name): no rim")
                    let rim = try #require(header.pill.borderColor.flatMap(NSColor.init(cgColor:)))
                    #expect(rim.alphaComponent > 0.2, "\(glass) \(name): the rim is \(rim.alphaComponent)")
                    let shown = try GroupPaletteDefaultTests.rgb(header.pill.backgroundColor).withAlpha(fill.alphaComponent)
                        .composited(over: scope.tokens.sidebarBackground)
                    let ink = try GroupPaletteDefaultTests.rgb(header.name.textColor?.cgColor)
                    #expect(ink.contrast(with: shown) >= ThemeTokens.minimumTextContrast - 0.05, "\(glass) \(name): the name reads \(ink.contrast(with: shown)):1")
                }
            }
        }
    }

    /// Richer chroma than the line color, the same hue family: vibrant on glass, not muddy.
    @Test func theGlassTintIsMoreSaturatedThanTheLine() {
        func chroma(_ c: ThemeRGB) -> Double { max(c.red, c.green, c.blue) - min(c.red, c.green, c.blue) }
        for color in GroupColor.allCases where color != .grey {
            let tint = GroupTint.palette(color)
            #expect(chroma(tint.glassRGB(themed: false)) >= chroma(tint.lineRGB(themed: false)), "\(color)")
        }
        #expect(GroupTint.none.glassRGB(themed: false) == (ThemeContext.active ?? ThemeScope.app.tokens).textPrimary.withAlpha(1),
                "no color is untinted glass")
    }

    @Test func theSolidBarStaysAChoice() throws {
        try Self.withGlass(.solid) {
            let (sidebar, ids) = try GroupPaletteDefaultTests.sidebar([.red])
            sidebar.layoutSubtreeIfNeeded()
            let header = try #require(sidebar.list.rowViews[.group(ids[0])] as? GroupHeaderRowView)
            header.updateLayer()
            #expect(header.pill.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent == 1)
            #expect(header.pill.borderWidth == 0)
        }
    }

    @Test func theNameIsTheRowsSizeSemibold() {
        for bar in [CGFloat(20), 26, 30] {
            let font = SidebarStyle.groupHeaderFont(barHeight: bar)
            #expect(font.pointSize == SidebarStyle.titleFont.pointSize)
            let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
            #expect((weight ?? 0) >= NSFont.Weight.semibold.rawValue - 0.01)
        }
    }
}
