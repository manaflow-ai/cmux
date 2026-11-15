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

    /// A group with no color takes no glass: its chip keeps #39594's faint neutral step and no rim, under the glass
    /// look too (GroupNoChosenColorTests).
    @Test func aGroupWithNoColorTakesNoGlass() {
        let chip = TabGroupChipCell(group: TabGroupItem(id: "g", name: "API", tint: .none), memberCount: 1)
        chip.look = Self.glass
        #expect(chip.pill.backgroundColor?.components == chip.themeScope.perform { Palette.sidebarStep.cgColor }.components)
        #expect(chip.rim.isHidden)
    }

    /// Leo 2026-11-05, "this strange font of the group on the side": a vertical list group header's name is the tab
    /// rows' own font, not the smaller caption face.
    @Test func theVerticalListsGroupNameIsTheRowsFont() {
        #expect(VerticalTabListView.groupNameFont == Typography.body)
        #expect(VerticalTabListView.groupNameFont.pointSize > Typography.caption.pointSize || Typography.body == Typography.caption)
    }

    /// The chip follows the sidebar headers' `sidebar.groupGlass`, Vivid by default.
    @Test func theChipFollowsTheHeadersGlassDefault() {
        #expect(GroupChipGlass.current.glass == SidebarGroupGlass.tunable.value)
        #expect(SidebarGroupGlass.tunable.defaultValue == .vivid)
    }

    /// A gradient or border change is part of the look, so the strip's observation hands it to the chip.
    @Test func theLookCarriesTheGradientAndBorders() {
        #expect(GroupChipGlass.current.gradient == DesignSettings.shared.sidebarSections.groupGradient)
        #expect(GroupChipGlass.current.borders == Borders.current)
        var other = Self.glass
        other.gradient = GroupGradient.allCases.first { $0 != Self.glass.gradient } ?? Self.glass.gradient
        #expect(other != Self.glass || GroupGradient.allCases.count == 1)
    }

    /// `appearance.borders: none` takes the rim's hairline away with the look, without a relayout.
    @Test func bordersNoneRemovesTheRimWithoutRelayout() throws {
        let scope = try #require(GroupPaletteDefaultTests.themes().first?.1)
        let chip = Self.chip(.blue, scope: scope)
        let stroke = try #require(chip.rim.mask as? CAShapeLayer)
        #expect(stroke.lineWidth > 0)
        var none = Self.glass
        none.borders = Borders(mode: .none)
        chip.look = none
        #expect(stroke.lineWidth == 0)
        chip.look = Self.glass
        #expect(stroke.lineWidth > 0)
    }

    /// Reduce Transparency is a notification, not an observed setting: a live chip goes opaque with a hairline
    /// when it turns on, and back to glass with its rim when it turns off.
    @Test func aChipFollowsReduceTransparency() throws {
        let scope = try #require(GroupPaletteDefaultTests.themes().first?.1)
        let chip = Self.chip(.purple, scope: scope)
        let saved = ReduceTransparency.shared.override
        defer { ReduceTransparency.shared.override = saved }
        ReduceTransparency.shared.override = false
        #expect(!chip.rim.isHidden && chip.pill.borderWidth == 0)
        ReduceTransparency.shared.override = true
        #expect(chip.rim.isHidden && chip.pill.borderWidth > 0)
        #expect(chip.pill.backgroundColor?.alpha == 1)
        ReduceTransparency.shared.override = false
        #expect(!chip.rim.isHidden && chip.pill.borderWidth == 0)
    }
}
