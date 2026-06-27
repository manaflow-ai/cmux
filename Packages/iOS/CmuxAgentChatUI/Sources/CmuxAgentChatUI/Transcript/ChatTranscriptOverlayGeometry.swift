#if os(iOS)
import CoreGraphics
import Observation
import SwiftUI

@MainActor
@Observable
final class ChatTranscriptOverlayGeometry {
    var composerBottomInset: CGFloat = 0
}

private struct ChatTranscriptOverlayGeometryKey: EnvironmentKey {
    static let defaultValue: ChatTranscriptOverlayGeometry? = nil
}

extension EnvironmentValues {
    var chatTranscriptOverlayGeometry: ChatTranscriptOverlayGeometry? {
        get { self[ChatTranscriptOverlayGeometryKey.self] }
        set { self[ChatTranscriptOverlayGeometryKey.self] = newValue }
    }
}
#endif
