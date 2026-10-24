import AppKit
import CmuxNextCompat

/// Follows the strip's window occlusion: busy tab indicators spin only while the window is on
/// screen and not fully covered (cx-qtgj2), as the sidebar list pauses its rows. Shaped like
/// `WindowMainObserver`: the block captures only `self`.
@MainActor
final class WindowVisibilityObserver {
    private(set) var isVisible = true
    private weak var window: NSWindow?
    private var onChange: (Bool) -> Void = { _ in }
    private var observer: MainActorObservation?
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
    // thread) runs no runtime hop; an implicit deinit is isolated in this target. The occlusion
    // observer (a MainActorObservation) is removed on the releasing thread.
    nonisolated deinit {}

    /// Starts following `window` (nil stops) and reports its current state.
    func observe(_ window: NSWindow?, onChange: @escaping (Bool) -> Void) {
        observer = nil
        self.window = window
        self.onChange = onChange
        guard let window else { return }
        changed()
        observer = MainActorObservation(NSWindow.didChangeOcclusionStateNotification, object: window, center: center) { [weak self] in
            self?.changed()
        }
    }

    private func changed() {
        guard let window else { return }
        isVisible = window.occlusionState.contains(.visible)
        onChange(isVisible)
    }
}
