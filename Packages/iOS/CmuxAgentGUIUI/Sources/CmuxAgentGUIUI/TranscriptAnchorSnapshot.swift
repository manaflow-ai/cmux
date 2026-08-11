#if os(iOS)
import CmuxAgentGUIProjection
import CoreGraphics

struct TranscriptAnchorSnapshot {
    let rowID: TranscriptRowID
    let screenY: CGFloat
    let pinsExactBottomRest: Bool
}
#endif
