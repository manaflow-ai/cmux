import AppKit

/// Follows the strip's window occlusion: busy tab indicators spin only while the window is on
/// screen and not fully covered (cx-qtgj2), as the sidebar list pauses its rows.
@MainActor
final class WindowVisibilityObserver {
    private(set) var isVisible = true
    private var observer: NSObjectProtocol?

    /// Starts following `window` (nil stops) and reports its current state.
    func observe(_ window: NSWindow?, onChange: @escaping (Bool) -> Void) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        isVisible = window.occlusionState.contains(.visible)
        onChange(isVisible)
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            // main-proof: the observer runs on the main queue (queue: .main)
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.isVisible = window.occlusionState.contains(.visible)
                onChange(self.isVisible)
            }
        }
    }
}
