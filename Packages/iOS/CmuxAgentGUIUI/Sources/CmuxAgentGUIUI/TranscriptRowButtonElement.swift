#if os(iOS)
import CoreGraphics

struct TranscriptRowButtonElement {
    let frame: CGRect
    let title: String?
    let kind: TranscriptRowButtonKind
    let isEnabled: Bool
    let accessibilityIdentifier: String?
    let accessibilityLabel: String?
    let accessibilityHint: String?
}
#endif
