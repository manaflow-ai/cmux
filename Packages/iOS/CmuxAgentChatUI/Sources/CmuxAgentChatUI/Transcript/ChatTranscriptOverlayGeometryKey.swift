#if os(iOS)
import SwiftUI

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
