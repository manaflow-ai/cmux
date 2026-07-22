#if os(iOS)
import CoreGraphics
import UIKit

struct TranscriptRowTextElement: Sendable {
    let attributedText: TranscriptAttributedText
    let frame: CGRect
    let role: TranscriptRowTextRole
    let alignment: NSTextAlignment
    let maximumNumberOfLines: Int
}
#endif
