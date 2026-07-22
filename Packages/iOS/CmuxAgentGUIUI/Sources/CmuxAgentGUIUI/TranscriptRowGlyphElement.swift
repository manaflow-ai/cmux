#if os(iOS)
import CoreGraphics

struct TranscriptRowGlyphElement {
    let frame: CGRect
    let systemName: String
    let pointSize: CGFloat
    let weight: CGFloat
    let role: TranscriptRowGlyphRole
    let isActivityIndicator: Bool
}
#endif
