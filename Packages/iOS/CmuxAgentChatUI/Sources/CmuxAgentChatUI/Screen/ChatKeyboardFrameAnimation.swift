#if os(iOS)
import CmuxMobileSupport
import CoreGraphics

struct ChatKeyboardFrameAnimation {
    let id: Int
    let startOverlap: CGFloat
    let targetOverlap: CGFloat
    let scrollSnapshots: [(scrollView: ChatTranscriptUITableView, snapshot: MobileScrollViewportSnapshot)]
}
#endif
