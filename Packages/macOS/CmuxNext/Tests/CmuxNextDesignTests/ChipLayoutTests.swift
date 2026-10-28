import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// Pane chrome chips (the terminal's status banner and "Sized for" chip, the
/// omnibar's badges) lay out by frames from ``ChipLayout``, a pure function, not Auto Layout. A pane
/// resized every frame of a drag then solves no constraints for them (Chromium's views::BoxLayout).
struct ChipLayoutTests {
    /// A 40x14 label then a 50x20 button, 8 apart, inset 12 before and 4 after, 3 above and below.
    private let labelAndButton = ChipLayout(items: [ChipLayout.Item(CGSize(width: 40, height: 14), flexible: true),
                                                    ChipLayout.Item(CGSize(width: 50, height: 20))],
                                            spacing: 8, insets: ChipLayout.Insets(top: 3, leading: 12, bottom: 3, trailing: 4))

    @Test func thePreferredSizeIsTheItemsSpacingAndInsets() {
        #expect(labelAndButton.preferredSize == CGSize(width: 12 + 40 + 8 + 50 + 4, height: 3 + 20 + 3))
    }

    @Test func aMinimumHeightAndMaximumWidthBound() {
        var chip = labelAndButton
        chip.minHeight = 30
        chip.maxWidth = 100
        #expect(chip.preferredSize == CGSize(width: 100, height: 30))
    }

    @Test func atItsPreferredSizeEachItemKeepsItsSizeCenteredInReadingOrder() {
        let frames = labelAndButton.frames(in: labelAndButton.preferredSize)
        #expect(frames == [CGRect(x: 12, y: 6, width: 40, height: 14), CGRect(x: 60, y: 3, width: 50, height: 20)])
    }

    @Test func aNarrowChipTruncatesTheFlexibleItemNeverTheButton() {
        let frames = labelAndButton.frames(in: CGSize(width: 94, height: 26))
        #expect(frames[0].width == 20, "the label gives up the 20 pt the chip lacks")
        #expect(frames[1] == CGRect(x: 40, y: 3, width: 50, height: 20))
    }

    @Test func aChipNarrowerThanItsFixedItemsGivesTheFlexibleOneNoNegativeWidth() {
        let frames = labelAndButton.frames(in: CGSize(width: 30, height: 26))
        #expect(frames[0].width == 0)
        #expect(frames[1].width == 50)
    }

    @Test func aWideChipGivesTheSpareWidthToTheFlexibleItem() {
        let frames = labelAndButton.frames(in: CGSize(width: 134, height: 26))
        #expect(frames[0].width == 60)
        #expect(frames[1].maxX == 130, "the button stays 4 pt from the trailing edge")
    }

    @Test func rightToLeftReadsFromTheTrailingEdge() {
        let size = labelAndButton.preferredSize
        let frames = labelAndButton.frames(in: size, rightToLeft: true)
        #expect(frames[0] == CGRect(x: size.width - 52, y: 6, width: 40, height: 14), "the label 12 pt from the right edge")
        #expect(frames[1] == CGRect(x: 4, y: 3, width: 50, height: 20), "the button 4 pt from the left edge")
    }

    @Test func aTallerChipCentersItsItemsOnWholePoints() {
        let badge = ChipLayout(items: [ChipLayout.Item(CGSize(width: 30, height: 13), flexible: true)],
                               insets: ChipLayout.Insets(horizontal: 6, vertical: 0), minHeight: 18)
        #expect(badge.preferredSize == CGSize(width: 42, height: 18))
        #expect(badge.frames(in: badge.preferredSize) == [CGRect(x: 6, y: 3, width: 30, height: 13)])
    }

    /// A glyph and a label 12 apart, at least 16 from each side: the drop overlay's card row.
    private let glyphAndLabel = ChipLayout(items: [ChipLayout.Item(CGSize(width: 16, height: 16)),
                                                   ChipLayout.Item(CGSize(width: 60, height: 14), flexible: true)],
                                           spacing: 12, insets: ChipLayout.Insets(horizontal: 16, vertical: 0))

    @Test func placedCenteredTheRowKeepsItsNaturalWidthInTheMiddle() {
        let frames = glyphAndLabel.frames(placedIn: CGRect(x: 0, y: 0, width: 200, height: 40), centered: true)
        // Natural width 16 + 16 + 12 + 60 + 16 = 120, so the row starts 40 in.
        #expect(frames == [CGRect(x: 56, y: 12, width: 16, height: 16), CGRect(x: 84, y: 13, width: 60, height: 14)])
    }

    @Test func placedInANarrowBoundsTheLabelTruncatesInsideTheInsets() {
        let frames = glyphAndLabel.frames(placedIn: CGRect(x: 0, y: 0, width: 100, height: 40), centered: true)
        #expect(frames[0].minX == 16, "the glyph keeps its 16 pt inset")
        #expect(frames[1].width == 40, "the label gives up the 20 pt the row lacks")
        #expect(frames[1].maxX == 84)
    }

    @Test func placedAtTheLeadingEdgeTheRowFollowsReadingOrderAndTheBoundsOrigin() {
        let bounds = CGRect(x: 10, y: 5, width: 200, height: 30)
        let ltr = glyphAndLabel.frames(placedIn: bounds)
        #expect(ltr[0] == CGRect(x: 26, y: 12, width: 16, height: 16))
        let rtl = glyphAndLabel.frames(placedIn: bounds, rightToLeft: true)
        #expect(rtl[0].maxX == bounds.maxX - 16, "right to left, the glyph leads at the right edge")
        #expect(rtl[1].maxX == rtl[0].minX - 12)
    }

    @Test func placedInNoRoomTheLabelGetsNoWidthNotANegativeOne() {
        let frames = glyphAndLabel.frames(placedIn: CGRect(x: 0, y: 0, width: 0, height: 20), centered: true)
        #expect(frames[1].width == 0)
    }

    @Test func noItemsIsJustTheInsets() {
        let empty = ChipLayout(items: [], spacing: 8, insets: ChipLayout.Insets(horizontal: 6, vertical: 2))
        #expect(empty.preferredSize == CGSize(width: 12, height: 4))
        #expect(empty.frames(in: CGSize(width: 50, height: 10)).isEmpty)
    }
}
