#if os(iOS)
import CoreGraphics
import Observation

@MainActor
@Observable
public final class ChatTranscriptOverlayGeometry {
    public internal(set) var composerBottomInset: CGFloat = 0
}
#endif
