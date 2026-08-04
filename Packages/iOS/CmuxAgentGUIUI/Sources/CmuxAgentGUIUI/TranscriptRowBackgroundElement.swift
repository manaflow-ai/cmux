#if os(iOS)
import CoreGraphics

struct TranscriptRowBackgroundElement: Sendable {
    let frame: CGRect
    let kind: TranscriptRowBackgroundKind
    let cornerRadius: CGFloat
}
#endif
