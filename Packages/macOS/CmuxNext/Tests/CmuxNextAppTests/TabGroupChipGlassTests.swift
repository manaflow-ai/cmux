import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxTheme
import Testing

/// Leo's ask, "Restyle tab group colors as vibrant glass with rim": a tab group chip is the sidebar group headers'
/// tinted glass with a rim (#36225, ``GroupChipGlass``), in every theme; solid (`sidebar.groupHeader.background`)
/// keeps the opaque fill; the look never changes the chip's size, and hover and press step over the glass.
@MainActor @Suite(.serialized) struct TabGroupChipGlassTests {
    static let glass = GroupChipGlass(glass: .vivid, background: .glass, palette: .vibrant)

    static func chip(_ color: GroupColor, look: GroupChipGlass = glass, scope: ThemeScope) -> TabGroupChipCell {
        let chip = TabGroupChipCell(group: TabGroupItem(id: "g", name: "API", colorToken: color), memberCount: 3)
        chip.look = look
        chip.themeScope = scope
        chip.scale = 2
        chip.frame = CGRect(x: 0, y: 0, width: chip.slotWidth, height: 32)
        return chip
    }

    @Test func aChipIsATranslucentTintedPaneWithARimInEveryTheme() throws {
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            for color in GroupColor.allCases where color != .grey {
                let chip = Self.chip(color, scope: scope)
                let fill = try #require(chip.pill.backgroundColor.flatMap(NSColor.init(cgColor:)))
                #expect(fill.alphaComponent > 0.05 && fill.alphaComponent < 0.7, "\(name) \(color): the pane is \(fill.alphaComponent) opaque")
                #expect(!chip.rim.isHidden, "\(name) \(color): no rim")
                #expect(chip.rim.frame == chip.pill.bounds, "\(name) \(color): the rim does not follow the pill")
                let shown = try GroupPaletteDefaultTests.rgb(chip.pill.backgroundColor).withAlpha(fill.alphaComponent)
                    .composited(over: scope.tokens.chromeBackground)
                #expect(shown.contrast(with: scope.tokens.chromeBackground.withAlpha(1)) >= GroupBackground.minimumVisibleContrast - 0.01,
                        "\(name) \(color): the pane does not show over the strip")
            }
        }
    }

    @Test func solidKeepsTheOpaqueFillAndNoRim() throws {
        let solid = GroupChipGlass(glass: .vivid, background: .solid, palette: .vibrant)
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            let chip = Self.chip(.purple, look: solid, scope: scope)
            #expect(chip.rim.isHidden, "\(name): solid draws no rim")
            #expect(chip.pill.backgroundColor?.alpha == 1, "\(name): solid is opaque")
        }
    }

    @Test func theLookNeverChangesTheChipsSize() throws {
        let scope = try #require(GroupPaletteDefaultTests.themes().first?.1)
        let chip = Self.chip(.blue, scope: scope)
        let width = chip.slotWidth, pill = chip.pillFrame
        chip.look = GroupChipGlass(glass: .vivid, background: .solid, palette: .vibrant)
        chip.layoutLayers()
        #expect(chip.slotWidth == width && chip.pillFrame == pill)
        chip.look = Self.glass
        chip.isHovered = true
        chip.isPressed = true
        chip.layoutLayers()
        #expect(chip.slotWidth == width && chip.pillFrame == pill)
    }

    @Test func hoverAndPressStepOverTheGlass() throws {
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            let chip = Self.chip(.green, scope: scope)
            let rest = chip.pill.backgroundColor
            chip.isHovered = true
            let hovered = chip.pill.backgroundColor
            chip.isPressed = true
            let pressed = chip.pill.backgroundColor
            #expect(rest != hovered && hovered != pressed, "\(name): hover and press do not show")
            #expect(!chip.rim.isHidden, "\(name): the rim stays through hover and press")
        }
    }

    @Test func aGroupWithNoColorKeepsItsChipClear() {
        let chip = TabGroupChipCell(group: TabGroupItem(id: "g", name: "API", tint: .none), memberCount: 1)
        chip.look = Self.glass
        #expect((chip.pill.backgroundColor?.alpha ?? 0) == 0)
        #expect(chip.rim.isHidden)
    }

    /// The chip follows the sidebar headers' `sidebar.groupGlass`, Vivid by default.
    @Test func theChipFollowsTheHeadersGlassDefault() {
        #expect(GroupChipGlass.current.glass == SidebarGroupGlass.tunable.value)
        #expect(SidebarGroupGlass.tunable.defaultValue == .vivid)
    }
}
