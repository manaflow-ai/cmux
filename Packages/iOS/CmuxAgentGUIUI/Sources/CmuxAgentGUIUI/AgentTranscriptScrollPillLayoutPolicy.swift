#if os(iOS)
import CoreGraphics

enum AgentTranscriptScrollPillLayoutPolicy {
    static func bottomPadding(composerBottomInset: CGFloat) -> CGFloat {
        let clearance = max(0, ceil(composerBottomInset))
        return max(10, clearance + 10)
    }
}
#endif
