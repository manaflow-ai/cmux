#if os(iOS)
import CoreGraphics

struct TranscriptRowButtonElement: Sendable {
    static let optionHorizontalContentInset: CGFloat = 12
    static let optionVerticalContentInset: CGFloat = 7

    let frame: CGRect
    let title: String?
    let kind: TranscriptRowButtonKind
    let isEnabled: Bool
    let accessibilityIdentifier: String?
    let accessibilityLabel: String?
    let accessibilityHint: String?
}
#endif
