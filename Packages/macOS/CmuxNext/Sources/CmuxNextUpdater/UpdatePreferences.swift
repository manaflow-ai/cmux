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
    /// `updates.oneClickInstall`: Update on a found update is also the restart's ask (its download
    /// shows its progress, then cmux installs and relaunches); off, the Update Ready card asks again.
    public var oneClickInstall: Bool
    /// `updates.whatsNewInstall`: What's New lists Install on each build (ChangelogInstallProvider).
    public var whatsNewInstall: Bool

    public init(installOnQuit: Bool = false, notify: UpdateNotifyMode = .badge, keepPreviousVersions: Int = 1,
                oneClickInstall: Bool = false, whatsNewInstall: Bool = false) {
        self.whatsNewInstall = whatsNewInstall
        self.installOnQuit = installOnQuit
        self.notify = notify
        self.keepPreviousVersions = keepPreviousVersions
        self.oneClickInstall = oneClickInstall
    }

    public static let defaults = UpdatePreferences()
}
