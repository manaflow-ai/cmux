import AppKit
import CmuxNextWakeups

extension HomeNativeTranscriptView {
    /// The transcript draws as seen only in the key window while that window is visible.
    func windowStateChanged() {
        transcript.isVisibleToUser = window.map { $0.isKeyWindow && $0.occlusionState.contains(.visible) } ?? false
    }

    /// After each layout pass of this view's window, the transcript reads its window place again (an ancestor
    /// may have moved it without laying it out; its typing indicator snaps to device pixels). Events with no
    /// layout, such as each key typed in the field, read nothing.
    func followLayoutPasses() {
        layoutPassWatch = (window as? any WindowLayoutPassHosting)?.layoutPasses.observe(owner: "HomeNativeTranscriptView") { [weak self] in
            self?.transcript.windowDidLayout()
        }
    }
}
