import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Follows the strip's window node (``WindowVisibilitySource``): busy tab indicators spin only
/// while the window is on screen and not fully covered, and the app is not hidden (cx-qtgj2), as
/// the sidebar list pauses its rows. A thin wrapper over the node; the block captures only `self`.
@MainActor
final class WindowVisibilityObserver {
    private(set) var isVisible = true
    private var onChange: (Bool) -> Void = { _ in }
    private var subscription: VisibilitySubscription?

    /// Starts following `window` (nil stops) and reports its current state.
    func observe(_ window: NSWindow?, onChange: @escaping (Bool) -> Void) {
        subscription = nil
        self.onChange = onChange
        guard let window else { return }
        let node = WindowVisibilitySource.of(window).node
        isVisible = node.isVisible
        onChange(isVisible)
        subscription = node.subscribe(owner: "TabStrip.windowVisibility") { [weak self] visibility in
            self?.changed(visibility.isVisible)
        }
    }

    private func changed(_ visible: Bool) {
        // Occluded to hidden flips the node but not what the strip shows.
        guard visible != isVisible else { return }
        isVisible = visible
        onChange(visible)
    }
}
