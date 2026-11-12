import Foundation
import Observation

/// The tmux overlay experiment target, read from `UserDefaults` once and kept
/// current by key-value observation of its two keys.
///
/// The main window resolves this target on every SwiftUI update, both to
/// build the workspace pane overlay and to decide whether terminal panes draw
/// their own unread ring. ``TmuxOverlayExperimentSettings/target(defaults:)``
/// costs two CFPreferences lookups per call, and those lookups were the
/// innermost frames of the main-thread hangs Sentry groups as
/// CMUXTERM-MACOS-1SKP (#15439). Reading ``target`` is a stored-property
/// read, and views that read it update when either key changes.
@MainActor
@Observable
final class TmuxOverlayExperimentTargetObserver {
    /// The experiment target the defaults currently resolve to.
    private(set) var target: TmuxOverlayExperimentTarget

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Reads the current target from `defaults` and starts observing its
    /// keys. Observation ends when the instance is released.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        target = TmuxOverlayExperimentSettings.target(defaults: defaults)
        observations = [
            defaults.observe(\.tmuxOverlayExperimentEnabled) { [weak self] _, _ in
                Self.defaultsDidChange(observer: self)
            },
            defaults.observe(\.tmuxOverlayExperimentTarget) { [weak self] _, _ in
                Self.defaultsDidChange(observer: self)
            },
        ]
    }

    /// Re-resolves the target, assigning only a changed value so views that
    /// read it don't update for writes that leave the target as it was.
    func refresh() {
        let resolved = TmuxOverlayExperimentSettings.target(defaults: defaults)
        guard resolved != target else { return }
        target = resolved
    }

    /// KVO reports a defaults change on the thread that wrote it. Always enqueue
    /// the refresh on the main actor because a main-thread callback is not
    /// necessarily executing inside a MainActor isolation context.
    private nonisolated static func defaultsDidChange(observer: TmuxOverlayExperimentTargetObserver?) {
        Task { @MainActor [weak observer] in observer?.refresh() }
    }
}

private extension UserDefaults {
    /// KVO-observable accessor for ``TmuxOverlayExperimentSettings/enabledKey``.
    /// `UserDefaults` is KVO-compliant for a key read through an `@objc
    /// dynamic` property of the same name, so the name must stay equal to
    /// the key (`"tmuxOverlayExperimentEnabled"`).
    @objc dynamic var tmuxOverlayExperimentEnabled: Bool {
        bool(forKey: TmuxOverlayExperimentSettings.enabledKey)
    }

    /// KVO-observable accessor for ``TmuxOverlayExperimentSettings/targetKey``.
    /// The name must stay equal to the key (`"tmuxOverlayExperimentTarget"`).
    @objc dynamic var tmuxOverlayExperimentTarget: String? {
        string(forKey: TmuxOverlayExperimentSettings.targetKey)
    }
}
