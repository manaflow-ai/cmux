import CoreGraphics
import Testing
@testable import CmuxCommandPalette

@Suite("Command palette panel placement")
struct CommandPalettePanelPlacementTests {
    @Test func centersBelowOwnerWindowTop() {
        let placement = CommandPalettePanelPlacement(
            ownerFrame: CGRect(x: 100, y: 100, width: 1_000, height: 700),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            contentSize: CGSize(width: 560, height: 480)
        )

        #expect(placement.frame == CGRect(x: 320, y: 280, width: 560, height: 480))
    }

    @Test func clampsCompletePanelInsideVisibleFrame() {
        let placement = CommandPalettePanelPlacement(
            ownerFrame: CGRect(x: 1_300, y: 10, width: 500, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            contentSize: CGSize(width: 560, height: 880)
        )

        #expect(placement.frame == CGRect(x: 868, y: 12, width: 560, height: 876))
    }
}
