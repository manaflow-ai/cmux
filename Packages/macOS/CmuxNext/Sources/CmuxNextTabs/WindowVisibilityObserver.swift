import AppKit
import CmuxNextDesign

/// Follows the strip's window occlusion: busy tab indicators spin only while the window is on
/// screen and not fully covered (cx-qtgj2), as the sidebar list pauses its rows. The window's one
/// occlusion observation is ``WindowOcclusionFamily``'s; this is the strip's follower of it.
@MainActor
final class WindowVisibilityObserver {
    private(set) var isVisible = true
    private weak var window: NSWindow?

    /// Starts following `window` (nil stops) and reports its current state.
    func observe(_ window: NSWindow?, onChange: @escaping (Bool) -> Void) {
        if let old = self.window, old !== window { WindowOcclusionFamily.of(old).unfollow(self) }
        self.window = window
        guard let window else { return }
        let family = WindowOcclusionFamily.of(window)
        family.follow(self) { [weak self] visible in
            self?.isVisible = visible
            onChange(visible)
        }
        isVisible = family.isVisible
        onChange(isVisible)
    }
}
