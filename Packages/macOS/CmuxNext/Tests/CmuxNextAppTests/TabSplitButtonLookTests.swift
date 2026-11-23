import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import QuartzCore
import Testing

/// Lucas 2026-11-12 ("Plus button: same height and roundness as tabs. It looks like a pill now."; "it shouldnt have any
/// colour/bakground on the group thing, only on hover"; "Sidebar row roundness must be exactly the same as tab
/// roundness"): the tab bar's split `+ ⌄` takes a tab's corner and curve (and the ⋮'s height, Lawrence 2026-11-20), draws no fill at rest, and
/// the sidebar's rows round exactly as the tabs do.
@MainActor struct TabSplitButtonLookTests {
    @Test func theSplitControlIsTheMoreButtonsSizeWithATabsCorner() {
        // Lawrence 2026-11-20: the + rounds as a tab and is the pane ⋮'s size, in every look.
        #expect(NewTabButtonView.splitCornerRadius == min(Metrics.tabCornerRadius, Metrics.tabBarControlSide / 2))
        #expect(NewTabButtonView.frameHeight == TitlebarBandButton.side, "the + is the ⋮'s height")
    }

    @Test func sidebarRowsRoundExactlyAsTabsDo() {
        #expect(SidebarDensityTokens.rowCornerRadius == Metrics.tabCornerRadius)
        #expect(Metrics.tabCornerCurve == .circular, "Helium's circular arcs by default, for tabs and rows alike")
    }

    @Test func noFillAtRestAndTheHoveredSegmentFillsUnderThePointer() {
        #expect(PlusButtonLook.fill(.init(hovering: false, pressed: false, siblingHovered: false), hoverStyle: .plate, segment: .leading) == nil, "no fill at rest")
        #expect(PlusButtonLook.fill(.init(hovering: true, pressed: false, siblingHovered: false), hoverStyle: .plate, segment: .leading) == Palette.hoverFill, "the hovered half")
        #expect(PlusButtonLook.fill(.init(hovering: true, pressed: true, siblingHovered: false), hoverStyle: .plate, segment: .leading) == Palette.pressedFill, "a press")
        let soft = PlusButtonLook.fill(.init(hovering: false, pressed: false, siblingHovered: true), hoverStyle: .plate, segment: .leading)
        #expect(soft != nil, "the other half shows a fill under the pointer")
        #expect((soft?.alphaComponent ?? 1) < Palette.hoverFill.alphaComponent, "the other half, softer")
    }

    /// Debug `tabs.chevronOnHover` (on by default): the ⌄ shows only under the pointer or with a menu open.
    @Test func theChevronShowsOnlyOnHoverWhenAsked() {
        #expect(TabStripView.revealsChooser(onHoverOnly: false, plusHovered: false, chooserHovered: false, menuOpen: false))
        #expect(!TabStripView.revealsChooser(onHoverOnly: true, plusHovered: false, chooserHovered: false, menuOpen: false))
        #expect(TabStripView.revealsChooser(onHoverOnly: true, plusHovered: true, chooserHovered: false, menuOpen: false))
        #expect(TabStripView.revealsChooser(onHoverOnly: true, plusHovered: false, chooserHovered: true, menuOpen: false))
        #expect(TabStripView.revealsChooser(onHoverOnly: true, plusHovered: false, chooserHovered: false, menuOpen: true))
        #expect(TabStripView.revealsChooser(onHoverOnly: true, plusHovered: false, chooserHovered: false, menuOpen: false,
                                          accessibilityFocused: true), "VoiceOver focus keeps the chooser visible")
        #expect(TabTunables.chevronOnHover.defaultValue == true, "the ⌄ shows on hover of the + by default (Lucas 2026-11-12)")
    }

    /// Lucas 2026-11-12 ("the chevron should only show up when the + button is hovered directly"): a hover on the
    /// strip's empty space revealed the ⌄ with the +, since both faded with the strip. Under `tabs.chevronOnHover` the
    /// ⌄ stays out of the strip's reveal; the + keeps it.
    @Test func theChevronNeverFadesInWithTheStripWhenItShowsOnlyOnThePlusHover() {
        #expect(TabStripRevealController.joinsStripReveal(plusMode: .hover, isChooser: false, chooserOnHover: true))
        #expect(!TabStripRevealController.joinsStripReveal(plusMode: .hover, isChooser: true, chooserOnHover: true))
        #expect(TabStripRevealController.joinsStripReveal(plusMode: .hover, isChooser: true, chooserOnHover: false))
        #expect(!TabStripRevealController.joinsStripReveal(plusMode: .always, isChooser: false, chooserOnHover: true))
    }
}
