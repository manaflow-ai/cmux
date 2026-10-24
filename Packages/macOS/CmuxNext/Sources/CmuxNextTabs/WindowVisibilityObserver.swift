import AppKit
import CmuxNextDesign

/// Follows the strip's window occlusion: busy tab indicators spin only while the window is on
/// screen and not fully covered (cx-qtgj2), as the sidebar list pauses its rows. Shaped like
/// `WindowMainObserver`: the window's ``WindowNotices`` observes the occlusion notice once for
/// every strip (and agent pane) in the window and calls this follower.
@MainActor
final class WindowVisibilityObserver: WindowNoticesFollower {
    private(set) var isVisible = true
    private weak var window: NSWindow?
    private var onChange: (Bool) -> Void = { _ in }
    /// The notices of the window it follows now (the window owns them).
    private weak var notices: WindowNotices?
    /// The center the window's occlusion changes arrive on (AppKit posts them on `NotificationCenter.default`).
    private let center: NotificationCenter

    /// Creates an observer that follows windows on `center`.
    ///
    /// - Parameter center: The center to observe (default `NotificationCenter.default`, where AppKit
    ///   posts the window's occlusion changes; tests pass their own).
    init(center: NotificationCenter = .default) {
        self.center = center
    }

    // cx-t7hu: nonisolated, so a release (inside an action's task-local scope, or off the main
    // thread) runs no runtime hop; an implicit deinit is isolated in this target. The window's
    // notices hold this follower weakly, so it drops out without a call.
    nonisolated deinit {}

    /// Starts following `window` (nil stops) and reports its current state.
    func observe(_ window: NSWindow?, onChange: @escaping (Bool) -> Void) {
        self.window = window
        self.onChange = onChange
        let next = window.map { WindowNotices.of($0, center: center) }
        if next !== notices {
            notices?.remove(self)
            next?.add(self, for: [.occlusionChanged])
            notices = next
        }
        guard window != nil else { return }
        changed()
    }

    func windowNoticed(_ notice: WindowNotice) {
        changed()
    }

    /// Reads the window's occlusion and reports it.
    private func changed() {
        guard let window else { return }
        isVisible = window.occlusionState.contains(.visible)
        onChange(isVisible)
    }
}
