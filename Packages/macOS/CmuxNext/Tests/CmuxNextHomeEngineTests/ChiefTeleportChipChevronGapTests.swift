import AppKit
import CmuxNextDesign
@testable import CmuxNextHomeEngine
import Testing

/// Leo, 2026-11-27: "these chevrons are too close dont we have any guidelines for these yet?"
/// A chevron starts at least 8 pt (docs/cmux-next/ui-guidelines.md) from the last ink of the label it follows.
@MainActor
struct ChiefTeleportChipChevronGapTests {
    @Test(arguments: [ChiefTeleportChipStyle.plain, .capsule, .outline])
    func chevronKeepsItsGapFromTheLabelInk(style: ChiefTeleportChipStyle) throws {
        let model = ChiefTeleportModel(showing: .thisMac, phase: .idle, destinations: [])
        let chip = ChiefTeleportChip(model: model, style: style)
        chip.frame = NSRect(origin: .zero, size: chip.intrinsicContentSize)
        chip.layoutSubtreeIfNeeded()
        let label = try #require(chip.subviews.first { $0 is ThemedLabel && !$0.isHidden })
        let chevron = try #require(chip.subviews.first { $0 is ThemedImageView && $0.frame.width > 0 && $0.frame.minX > label.frame.minX })
        let ink = label.frame.maxX - ChiefTeleportChip.labelInset
        #expect(chevron.frame.minX - ink >= 8 - 0.01)
    }
}
