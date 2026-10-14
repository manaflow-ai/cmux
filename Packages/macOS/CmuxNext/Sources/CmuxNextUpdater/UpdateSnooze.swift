public import Foundation

/// UPDATE-CARD-CLOSE (Lawrence 2026-10-14: "make sure we can close bottom left thing for check
/// for updates (like remind in X days, X button to close)"): what the update cards' x remembers
/// on this Mac (UserDefaults, as the tips do; never uploaded; kept across restarts and updates).
///
/// - ``closedVersion``: "Hide Until a Newer Version". The card for this update version stays
///   hidden; a different version (the feed offers only newer builds) shows again. This is not
///   Sparkle's "skip this version": Sparkle still downloads and stages the update, a quit still
///   installs it (`updates.installOnQuit`), and Check for Updates shows it.
/// - ``remindAfter``: "Remind Me in 1 Day / 3 Days / 1 Week". No update card before this moment,
///   for any version (a nightly ships about once a day, so a version-bound reminder would come
///   back the next morning).
///
/// A check or install the user asks for clears both, and so does the recheck of an update the
/// organization requires (managed MinimumVersion) (``UpdaterService/clearUpdateSnooze()``).
nonisolated public struct UpdateSnooze: Equatable, Sendable {
    /// The update version whose card the person closed ("" when the update named no version).
    public var closedVersion: String?
    /// No update card before this moment; nil: no reminder pending.
    public var remindAfter: Date?

    public init(closedVersion: String? = nil, remindAfter: Date? = nil) {
        self.closedVersion = closedVersion
        self.remindAfter = remindAfter
    }

    static let closedVersionKey = "cmux.next.updates.closedVersion"
    static let remindAfterKey = "cmux.next.updates.remindAfter"

    public init(defaults: UserDefaults) {
        closedVersion = defaults.string(forKey: Self.closedVersionKey)
        remindAfter = defaults.object(forKey: Self.remindAfterKey) as? Date
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(closedVersion, forKey: Self.closedVersionKey)
        defaults.set(remindAfter, forKey: Self.remindAfterKey)
    }

    /// Whether the card for update `version` stays hidden at `date`.
    public func hides(version: String?, at date: Date) -> Bool {
        if let remindAfter, date < remindAfter { return true }
        guard let closedVersion else { return false }
        return closedVersion == (version ?? "")
    }

    /// The same state without a reminder that ended at `date`.
    func expired(at date: Date) -> UpdateSnooze {
        guard let remindAfter, date >= remindAfter else { return self }
        return UpdateSnooze(closedVersion: closedVersion, remindAfter: nil)
    }
}

/// What the update cards' x and right-click menu offer (UPDATE-CARD-CLOSE), in menu order. The
/// set follows the tip card's x (Mute Tips for 1 Day / 1 Week) and adds 3 days for a long
/// weekend; past a week, "Hide Until a Newer Version" or Automatic Updates off says it better.
nonisolated public enum UpdateCardCloseOption: String, CaseIterable, Sendable {
    case hideVersion = "update-hide-version"
    case remindDay = "update-remind-day"
    case remindThreeDays = "update-remind-3-days"
    case remindWeek = "update-remind-week"

    public var title: String {
        switch self {
        case .hideVersion: UpdaterStrings.text("updater.close.hideVersion", "Hide Until a Newer Version")
        case .remindDay: UpdaterStrings.text("updater.close.remindDay", "Remind Me in 1 Day")
        case .remindThreeDays: UpdaterStrings.text("updater.close.remindThreeDays", "Remind Me in 3 Days")
        case .remindWeek: UpdaterStrings.text("updater.close.remindWeek", "Remind Me in 1 Week")
        }
    }

    /// How long a reminder waits; nil for Hide Until a Newer Version.
    public var remindLength: TimeInterval? {
        switch self {
        case .hideVersion: nil
        case .remindDay: 24 * 60 * 60
        case .remindThreeDays: 3 * 24 * 60 * 60
        case .remindWeek: 7 * 24 * 60 * 60
        }
    }
}
