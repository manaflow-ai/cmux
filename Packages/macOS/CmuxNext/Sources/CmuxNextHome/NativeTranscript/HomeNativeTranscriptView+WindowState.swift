import AppKit

extension HomeNativeTranscriptView {
    /// The transcript draws as seen only in the key window while that window is visible.
    func windowStateChanged() {
        transcript.isVisibleToUser = window.map(isWindowSeen) ?? false
    }
}
