import AppKit
import CmuxNextDesign

/// Follows the strip's window occlusion: busy tab indicators spin only while the window is on
/// screen and not fully covered (cx-qtgj2), as the sidebar list pauses its rows. Shaped like
/// `WindowMainObserver`: the block captures only `self`.
///
/// It hears the window through the window's ``WindowOcclusionFamily`` (one observer per window,
/// PATTERNS.md P3), so a window with a strip per pane does not hold an observer per strip.
@MainActor
final class WindowVisibilityObserver: WindowOcclusionFollowing {
    private(set) var isVisible = true
    private weak var window: NSWindow?
    /// The family it follows now (its window's while it observes one).
    private weak var family: WindowOcclusionFamily?
    private var onChange: (Bool) -> Void = { _ in }

    /// Starts following `window` (nil stops) and reports its current state.
    func observe(_ window: NSWindow?, onChange: @escaping (Bool) -> Void) {
        family?.remove(self)
        family = nil
        self.window = window
        self.onChange = onChange
        guard let window else { return }
        changed()
        let family = WindowOcclusionFamily.of(window)
        family.add(self)
        self.family = family
    }

    func windowOcclusionDidChange() {
        changed()
    }

    private func changed() {
        guard let window else { return }
        isVisible = window.occlusionState.contains(.visible)
        onChange(isVisible)
    }
}
