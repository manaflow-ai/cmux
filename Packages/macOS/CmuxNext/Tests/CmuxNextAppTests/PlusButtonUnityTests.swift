import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import QuartzCore
import Testing

/// Lawrence 2026-11-15: "hovering on plus button should have same plus button (without the chevron) as the new tab
/// plus button. we should make the new tab plus button the standard for all plus buttons (abstract it into a
/// component). and then we need to use the same plus button in the sidebar plus button. we need to make sure that
/// button sizes (including icon sizes) across the relevant buttons, are all consistent as well."
///
/// Every + host draws through `PlusButtonLook`: the tab bar's New Tab +, the sidebar's New Workspace +, a group's +, an
/// empty group's + and the plain `PlusButton`. At every density they draw the same + (extent and stroke), show the same
/// hover fill and the same lit ink while pressed. Before, the group's + was the icon pack's 7 pt + at a 0.75 pt
/// stroke beside the tab bar's 9 pt one, and a lone tab-bar + drew no hover fill while the sidebar's did.
@MainActor @Suite(.serialized) struct PlusButtonUnityTests {
    /// A host's + as (extent end to end, stroke), from its look's glyph layer after a layout.
    private static func glyph(_ look: PlusButtonLook?, host: NSView, sourceLocation: SourceLocation = #_sourceLocation) throws -> (extent: CGFloat, stroke: CGFloat) {
        let look = try #require(look, "the + is drawn by PlusButtonLook", sourceLocation: sourceLocation)
        host.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        host.layout()
        let box = try #require(look.glyphLayer.path, sourceLocation: sourceLocation).boundingBoxOfPath
        return (max(box.width, box.height), look.glyphLayer.lineWidth)
    }

    @Test(arguments: DensityPreset.allCases)
    func everyPlusDrawsTheNewTabPlusAtEveryDensity(density: DensityPreset) throws {
        _ = NSApplication.shared
        try DensityTokens.$scoped.withValue(density.tokens) {
            let tab = NewTabButtonView(frame: .zero)
            let standard = try Self.glyph(tab.look, host: tab)
            #expect(abs(standard.extent - Metrics.addGlyphExtent) < 0.01, "\(density): the tab + is the add glyph's extent")

            let sidebar = SidebarView(model: SidebarModel(), design: DesignSettings())
            let group = GroupHeaderRowView(key: .group(GroupID("grp_plus")))
            let empty = EmptyGroupRowView(key: .emptyGroup(GroupID("grp_plus")))
            let plain = PlusButton(label: "Add")
            let hosts: [(String, PlusButtonLook?, NSView)] = [
                ("sidebar New Workspace", sidebar.newButton.plusLook, sidebar.newButton),
                ("group header", group.addButton.plusLook, group.addButton),
                ("empty group", empty.addButton.plusLook, empty.addButton),
                ("PlusButton", plain.look, plain),
            ]
            for (name, look, host) in hosts {
                let drawn = try Self.glyph(look, host: host)
                #expect(abs(drawn.extent - standard.extent) < 0.01, "\(density) \(name): + \(drawn.extent) pt vs tab \(standard.extent) pt")
                #expect(abs(drawn.stroke - standard.stroke) < 0.01, "\(density) \(name): stroke \(drawn.stroke) vs tab \(standard.stroke)")
            }
        }
    }

    /// "hovering on plus button should have same plus button (without the chevron)": a lone + shows the tab bar's
    /// hover plate (the split look's + segment, all four corners) wherever it is; before, a lone tab-bar + in the
    /// plate look drew none.
    @Test func aLonePlusHoversAsTheTabBarsPlus() throws {
        _ = NSApplication.shared
        let tab = NewTabButtonView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        tab.hoverStyle = .plate
        tab.splitSegment = false
        tab.layout()
        tab.isHovered = true
        #expect(tab.look.fillLayer.backgroundColor != nil, "a lone tab + shows the hover plate")
        #expect(tab.look.fillLayer.maskedCorners == PlusButtonLook.allCorners)
        // Rounded as a tab (Lawrence 2026-11-20), never past a circle on its own side.
        #expect(tab.look.fillLayer.cornerRadius == min(Metrics.tabCornerRadius, 12), "a tab's corner on its side")

        let sidebar = SidebarView(model: SidebarModel(), design: DesignSettings())
        let look = try #require(sidebar.newButton.plusLook)
        #expect(look.hoverStyle == PlusButtonLook.defaultHoverStyle)
        #expect(!sidebar.newButton.hover.paintsFill, "the button's own chrome fill is off: the look paints the hover")
        look.apply(.init(hovering: true), animated: false)
        #expect(look.fillLayer.backgroundColor == tab.look.fillLayer.backgroundColor, "the same hover fill")
        #expect(look.glyphLayer.strokeColor == tab.look.glyphLayer.strokeColor, "the same hover ink")
    }

    @Test func aHeldPlusChangesOnlyItsFillAndAnOpenMenuLightsIt() {
        let lit = PlusButtonLook.glyphInk(hovering: true, pressed: true)
        #expect(lit == Palette.litGlyph)
        #expect(PlusButtonLook.glyphInk(hovering: false, pressed: false) == Palette.textSecondary)
        #expect(PlusButtonLook.glyphInk(hovering: true, pressed: false) == Palette.textPrimary)
        // design/pressed-state.md: a held + changes only its fill, its ink stays the hover ink.
        #expect(PlusButtonLook.ink(.init(hovering: true, pressed: true)) == PlusButtonLook.ink(.init(hovering: true)))
        #expect(PlusButtonLook.fill(.init(hovering: true, pressed: true), hoverStyle: .plate, segment: .alone) == Palette.pressedFill)
        #expect(PlusButtonLook.ink(.init(menuOpen: true)) == Palette.litGlyph, "an open menu lights the +")
        #expect(PlusButtonLook.fill(.init(menuOpen: true), hoverStyle: .plate, segment: .alone) == Palette.pressedFill)
        #expect(PlusButtonLook.fill(.init(hovering: true), hoverStyle: .glyph, segment: .alone) == nil, "the glyph look never fills")
    }

    /// The sidebar's + joined to its chooser segment is the split look's leading half, as the tab bar's.
    @Test func theSidebarPlusBesideItsChooserIsTheLeadingSegment() throws {
        _ = NSApplication.shared
        let design = DesignSettings()
        design.sidebarSections.showNewWorkspaceChooser = true
        let sidebar = SidebarView(model: SidebarModel(), design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 480)
        sidebar.layoutSubtreeIfNeeded()
        let look = try #require(sidebar.newButton.plusLook)
        #expect(look.segment == (sidebar.newWorkspaceOptionsButton.isHidden ? .alone : .leading))
    }
}
