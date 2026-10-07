import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// SIDEBAR-FOOTER-AND-SPACE-MENU F2 (Lawrence 2026-10-06): a space button
/// has padding and changes its background on hover, with the same hover
/// token as the sidebar rows; a press uses the pressed token. Each space
/// keeps at least the macOS minimum hit width.
@MainActor @Suite struct ProfileBarHoverTests {
    private func bar() -> ProfileBarView {
        let model = SidebarModel()
        model.profiles = [SidebarProfile(id: ProfileKey("default"), name: "Default"), SidebarProfile(id: ProfileKey("p2"), name: "Work"),
                          SidebarProfile(id: ProfileKey("p3"), name: "Play")]
        model.activeProfileID = ProfileKey("default")
        let view = ProfileBarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: Metrics.sidebarRowHeight)
        return view
    }

    @Test func noHoverDrawsNoBackground() {
        #expect(bar().hoverChip == nil)
    }

    @Test func aHoveredSpaceGetsTheRowHoverFillWithPadding() throws {
        let view = bar()
        view.setHovered(1)
        let chip = try #require(view.hoverChip)
        #expect(chip.fill == view.performWithTheme { Palette.hoverFill })
        // The chip pads the dot on every side and stays inside its slot.
        #expect(chip.rect.width >= Metrics.roomDotDiameter + Metrics.space2 * 2)
        #expect(chip.rect.height >= Metrics.roomDotDiameter + Metrics.space2 * 2)
        #expect(chip.rect.height <= view.bounds.height)
        view.setHovered(nil)
        #expect(view.hoverChip == nil)
    }

    @Test func aPressedSpaceUsesThePressedFill() throws {
        let view = bar()
        view.setHovered(2)
        view.setPressed(2)
        #expect(try #require(view.hoverChip).fill == view.performWithTheme { Palette.pressedFill })
    }

    @Test func eachSpaceIsAtLeastTheMinimumHitWidth() {
        #expect(Metrics.roomDotSlot >= 20)
    }
}
