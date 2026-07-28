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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        _ text: String,
        role: Role,
        alignment: TextAlignment
    ) {
        self.text = text
        self.role = role
        self.alignment = alignment
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
        let descriptor = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: role.textStyle
        )
        let baseFont = UIFont.systemFont(
            ofSize: descriptor.pointSize,
            weight: role.weight
        )

        label.text = text
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
        label.balancedDrawingWidth = balancedSize.width
        return CGSize(width: width, height: balancedSize.height)
    }

    static func balancedSize(
        for label: UILabel,
        maximumWidth: CGFloat
    ) -> CGSize {
        let unconstrainedHeight = CGFloat.greatestFiniteMagnitude
        let maximumSize = label.sizeThatFits(
            CGSize(width: maximumWidth, height: unconstrainedHeight)
        )
        let maximumHeight = ceil(maximumSize.height)

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
            let candidateHeight = label.sizeThatFits(
                CGSize(width: candidate, height: unconstrainedHeight)
            ).height
            if candidateHeight <= maximumHeight {
                upperBound = candidate
            } else {
                lowerBound = candidate
            }
        }

        let balancedWidth = min(maximumWidth, ceil(upperBound + 1))
        let balancedHeight = label.sizeThatFits(
            CGSize(width: balancedWidth, height: unconstrainedHeight)
        ).height
        return CGSize(width: balancedWidth, height: ceil(balancedHeight))
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
