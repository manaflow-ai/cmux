#if os(iOS)
import CmuxAgentGUIProjection
import CoreGraphics

struct TranscriptRowLayoutCacheEntry: Sendable {
    let row: TranscriptRow
    let width: CGFloat
    let density: TranscriptDensity
    let height: CGFloat
    let askState: TranscriptAskLayoutState
    let layout: TranscriptRowLayoutResult
}
#endif
