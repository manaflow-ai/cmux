#if os(iOS)
import CoreGraphics

struct TranscriptTextMeasurement: Sendable {
    let size: CGSize
    let codeBlockFrames: [CGRect]
}
#endif
