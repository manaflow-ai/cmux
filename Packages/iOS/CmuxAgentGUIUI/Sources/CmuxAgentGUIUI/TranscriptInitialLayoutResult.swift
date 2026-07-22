#if os(iOS)
import CmuxAgentGUIProjection

/// Completed cache and actual computation count from one off-main initial-layout batch.
struct TranscriptInitialLayoutResult: Sendable {
    let cache: [TranscriptRowID: TranscriptRowLayoutCacheEntry]
    let computationCount: Int
}
#endif
