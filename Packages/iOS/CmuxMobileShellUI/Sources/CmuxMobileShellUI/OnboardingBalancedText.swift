#if os(iOS)
import SwiftUI
import UIKit

/// Multiline onboarding copy that keeps the system line-break behavior while
/// narrowing each label to the smallest width that preserves its line count.
struct OnboardingBalancedText: UIViewRepresentable {
    enum Role: Equatable {
        case title
        case body

        var textStyle: UIFont.TextStyle {
            switch self {
            case .title: .largeTitle
            case .body: .body
            }
        }

        var weight: UIFont.Weight {
            switch self {
            case .title: .bold
            case .body: .regular
            }
        }

        var color: UIColor {
            switch self {
            case .title: .label
            case .body: .secondaryLabel
            }
        }
    }

    let text: String
    let role: Role
    let alignment: TextAlignment
    let maximumNumberOfLines: Int?
    /// Whether the label claims its full line-limit height even when the text
    /// needs fewer lines. Pages whose copy shares a screen-filling sibling
    /// (the onboarding visual takes the remaining height) reserve the space so
    /// a one-line body and a two-line body produce identically sized visuals.
    let reservesMaximumLines: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        _ text: String,
        role: Role,
        alignment: TextAlignment,
        maximumNumberOfLines: Int? = nil,
        reservesMaximumLines: Bool = false
    ) {
        self.text = text
        self.role = role
        self.alignment = alignment
        self.maximumNumberOfLines = maximumNumberOfLines
        self.reservesMaximumLines = reservesMaximumLines
    }

    func makeUIView(context: Context) -> OnboardingBalancedLabel {
        Self.makeLabel()
    }

    static func makeLabel() -> OnboardingBalancedLabel {
        let label = OnboardingBalancedLabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.lineBreakStrategy = .pushOut
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: OnboardingBalancedLabel, context: Context) {
        _ = dynamicTypeSize
        Self.configure(
            label,
            text: text,
            role: role,
            alignment: alignment,
            maximumNumberOfLines: maximumNumberOfLines
        )
    }

    static func configure(
        _ label: OnboardingBalancedLabel,
        text: String,
        role: Role,
        alignment: TextAlignment,
        maximumNumberOfLines: Int?
    ) {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: role.textStyle
        )
        let baseFont = UIFont.systemFont(
            ofSize: descriptor.pointSize,
            weight: role.weight
        )

        label.text = text
        label.numberOfLines = maximumNumberOfLines ?? 0
        label.font = UIFontMetrics(forTextStyle: role.textStyle)
            .scaledFont(for: baseFont)
        label.textColor = role.color
        label.textAlignment = alignment == .center ? .center : .natural
        label.accessibilityTraits = role == .title ? .header : .staticText
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView label: OnboardingBalancedLabel,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 1 else {
            return nil
        }
        let balancedSize = Self.balancedSize(
            for: label,
            maximumWidth: width
        )
        label.balancedDrawingWidth = balancedSize.width < width
            ? balancedSize.width
            : nil
        var height = balancedSize.height
        if reservesMaximumLines, let maximumNumberOfLines, maximumNumberOfLines > 0 {
            height = max(
                height,
                ceil(label.font.lineHeight * CGFloat(maximumNumberOfLines)) + 1
            )
        }
        return CGSize(width: width, height: height)
    }

    static func balancedSize(
        for label: UILabel,
        maximumWidth: CGFloat
    ) -> CGSize {
        let unconstrainedHeight = CGFloat.greatestFiniteMagnitude
        let lineLimit = label.numberOfLines
        let ignoresLineLimit = lineLimit > 0
        let maximumSize = measuredSize(
            for: label,
            width: maximumWidth,
            height: unconstrainedHeight,
            ignoresLineLimit: ignoresLineLimit
        )
        let maximumHeight = ceil(maximumSize.height)

        if lineLimit > 0 {
            let cappedHeight = ceil(label.sizeThatFits(
                CGSize(width: maximumWidth, height: unconstrainedHeight)
            ).height)
            let lineLimitHeight = ceil(label.font.lineHeight * CGFloat(lineLimit)) + 1

            guard maximumHeight <= lineLimitHeight else {
                return CGSize(width: maximumWidth, height: cappedHeight)
            }
        }

        guard maximumHeight > ceil(label.font.lineHeight) else {
            return CGSize(width: maximumWidth, height: maximumHeight)
        }

        // Find the narrowest width that preserves the line count selected at
        // the available width. Centering that compact label balances the line
        // lengths without inserting locale-specific manual breaks.
        var lowerBound: CGFloat = 1
        var upperBound = maximumWidth
        for _ in 0..<14 {
            let candidate = (lowerBound + upperBound) / 2
            let candidateHeight = measuredSize(
                for: label,
                width: candidate,
                height: unconstrainedHeight,
                ignoresLineLimit: ignoresLineLimit
            ).height
            if candidateHeight <= maximumHeight {
                upperBound = candidate
            } else {
                lowerBound = candidate
            }
        }

        let balancedWidth = min(maximumWidth, ceil(upperBound + 1))
        let balancedHeight = measuredSize(
            for: label,
            width: balancedWidth,
            height: unconstrainedHeight,
            ignoresLineLimit: ignoresLineLimit
        ).height
        return CGSize(width: balancedWidth, height: ceil(balancedHeight))
    }

    private static func measuredSize(
        for label: UILabel,
        width: CGFloat,
        height: CGFloat,
        ignoresLineLimit: Bool
    ) -> CGSize {
        let originalNumberOfLines = label.numberOfLines
        if ignoresLineLimit {
            label.numberOfLines = 0
        }
        defer {
            if ignoresLineLimit {
                label.numberOfLines = originalNumberOfLines
            }
        }
        return label.sizeThatFits(CGSize(width: width, height: height))
    }
}

final class OnboardingBalancedLabel: UILabel {
    var balancedDrawingWidth: CGFloat? {
        didSet {
            if oldValue != balancedDrawingWidth {
                setNeedsDisplay()
            }
        }
    }

    override func drawText(in rect: CGRect) {
        guard let balancedDrawingWidth,
              balancedDrawingWidth < rect.width else {
            super.drawText(in: rect)
            return
        }

        let originX: CGFloat
        switch textAlignment {
        case .center:
            originX = rect.midX - balancedDrawingWidth / 2
        case .right:
            originX = rect.maxX - balancedDrawingWidth
        case .natural where effectiveUserInterfaceLayoutDirection == .rightToLeft:
            originX = rect.maxX - balancedDrawingWidth
        default:
            originX = rect.minX
        }

        super.drawText(in: CGRect(
            x: originX,
            y: rect.minY,
            width: balancedDrawingWidth,
            height: rect.height
        ))
    }
}
#endif
