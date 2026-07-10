#if os(iOS)
import CmuxAgentGUIProjection
import CoreGraphics

struct TranscriptMeasuredRow: Hashable, Sendable {
    let row: TranscriptRow
    let height: CGFloat
}
#endif
