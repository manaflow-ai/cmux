#if os(iOS)
import CoreGraphics

struct TranscriptRowLayoutResult {
    let height: CGFloat
    let textElements: [TranscriptRowTextElement]
    let backgroundElements: [TranscriptRowBackgroundElement]
    let glyphElements: [TranscriptRowGlyphElement]
    let buttonElements: [TranscriptRowButtonElement]

    var elementFrames: [CGRect] {
        textElements.map(\.frame)
            + backgroundElements.map(\.frame)
            + glyphElements.map(\.frame)
            + buttonElements.map(\.frame)
    }

    var contentBounds: CGRect {
        elementFrames.reduce(CGRect.null) { $0.union($1) }
    }
}
#endif
