import Foundation

/// How a ready update makes itself known (`updates.notify`). The update
/// card and its quiet hours are gone (Lawrence 2026-10-05): a staged update
/// is the Settings row's control.
nonisolated public enum UpdateNotifyMode: String, Sendable, CaseIterable {
    /// The control on the Settings item.
    case badge
    /// Nothing shows; the update installs on quit (or by `cmux update install`).
    case silent
}

/// The user's update settings the install gate reads (`updates.*` in the
/// shared settings schema).
nonisolated public struct UpdatePreferences: Equatable, Sendable {
    public var installOnQuit: Bool
    public var notify: UpdateNotifyMode
    /// Previous builds kept for rollback.
    public var keepPreviousVersions: Int

    public init(installOnQuit: Bool = true, notify: UpdateNotifyMode = .badge, keepPreviousVersions: Int = 1) {
        self.installOnQuit = installOnQuit
        self.notify = notify
        self.keepPreviousVersions = keepPreviousVersions
    }

    public static let defaults = UpdatePreferences()
}
