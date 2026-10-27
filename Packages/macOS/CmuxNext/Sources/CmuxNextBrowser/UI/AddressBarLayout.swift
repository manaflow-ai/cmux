import CoreGraphics

/// The omnibar's inside: the page-info chip at the leading end, the trailing
/// badges, and the text field between them, all on the bar's center line.
nonisolated struct AddressBarLayout: Equatable, Sendable {
    struct Input: Equatable, Sendable {
        var size: CGSize
        /// The chip's width (its content, at least its height) and height.
        var chipSize: CGSize
        var fieldHeight: CGFloat
        /// Zero when no badge shows.
        var badgesSize: CGSize
        var chipLeading: CGFloat
        var textLeading: CGFloat
        var trailingPadding: CGFloat
        var badgesTrailing: CGFloat
        var cardTopOutset: CGFloat
        var cardSideOutset: CGFloat
    }

    var pill: CGRect
    /// The top of the suggestion card, behind the bar.
    var backdrop: CGRect
    var chip: CGRect
    var field: CGRect
    var badges: CGRect

    init(_ input: Input) {
        let size = CGSize(width: max(0, input.size.width), height: max(0, input.size.height))
        func centered(_ x: CGFloat, _ itemSize: CGSize) -> CGRect {
            CGRect(x: x, y: (size.height - itemSize.height) / 2, width: itemSize.width, height: itemSize.height)
        }
        pill = CGRect(origin: .zero, size: size)
        backdrop = CGRect(x: -input.cardSideOutset, y: -input.cardTopOutset,
                          width: size.width + 2 * input.cardSideOutset, height: size.height + input.cardTopOutset)
        chip = centered(input.chipLeading, input.chipSize)
        let showsBadges = input.badgesSize.width > 0
        badges = showsBadges ? centered(size.width - input.badgesTrailing - input.badgesSize.width, input.badgesSize) : .zero
        let fieldX = chip.maxX + input.textLeading
        let fieldEnd = showsBadges ? badges.minX - input.textLeading : size.width - input.trailingPadding
        field = centered(fieldX, CGSize(width: max(0, fieldEnd - fieldX), height: input.fieldHeight))
    }
}
