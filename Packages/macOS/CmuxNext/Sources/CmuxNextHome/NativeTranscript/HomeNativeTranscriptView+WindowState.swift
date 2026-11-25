import AppKit

extension HomeNativeTranscriptView {
    /// The transcript draws as seen only in the key window while that window is visible.
    func windowStateChanged() {
        transcript.isVisibleToUser = window.map { $0.isKeyWindow && $0.occlusionState.contains(.visible) } ?? false
    }
}
