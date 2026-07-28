#if os(iOS)
import CoreGraphics
import Observation

@MainActor
@Observable
final class ChatTranscriptOverlayGeometry {
    var composerBottomInset: CGFloat = 0
}
#endif
