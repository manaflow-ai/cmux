public import Foundation

/// Registers cmux's Sparkle preference defaults and performs the one-time migration that
/// repairs older installs whose automatic-check defaults predate the Info.plist-embedded
/// values.
///
/// The `SU…` keys are the standard Sparkle `UserDefaults` keys. The check intervals are
/// configuration, so this is a value type constructed with them (defaulting to cmux's
/// hourly check) and applied to a given `UserDefaults`.
public struct UpdateSettings: Sendable {
    /// Sparkle's "automatically check for updates" key.
    public static let automaticChecksKey = "SUEnableAutomaticChecks"
    /// Sparkle's "automatically download/install updates" key.
    public static let automaticallyUpdateKey = "SUAutomaticallyUpdate"
    /// Sparkle's scheduled-check-interval key.
    public static let scheduledCheckIntervalKey = "SUScheduledCheckInterval"
    /// Sparkle's "send anonymous system profile" key.
    public static let sendProfileInfoKey = "SUSendProfileInfo"
    /// cmux's marker that the v2 automatic-checks migration already ran.
    public static let migrationKey = "cmux.sparkle.automaticChecksMigration.v2"

    /// The previous default scheduled-check interval (24h) that the migration upgrades from.
    public let previousDefaultScheduledCheckInterval: TimeInterval
    /// The scheduled-check interval cmux registers (1h by default).
    public let scheduledCheckInterval: TimeInterval

    /// Creates the settings with cmux's defaults.
    ///
    /// - Parameter scheduledCheckInterval: How often Sparkle checks for updates, in seconds.
    ///   Defaults to one hour.
    /// - Parameter previousDefaultScheduledCheckInterval: The legacy interval the migration
    ///   upgrades away from when it sees it persisted. Defaults to 24 hours.
    public init(scheduledCheckInterval: TimeInterval = 60 * 60,
                previousDefaultScheduledCheckInterval: TimeInterval = 60 * 60 * 24) {
        self.scheduledCheckInterval = scheduledCheckInterval
        self.previousDefaultScheduledCheckInterval = previousDefaultScheduledCheckInterval
    }

    /// Registers the update defaults on `defaults` and runs the one-time migration.
    ///
    /// Registration is idempotent. The migration (guarded by ``migrationKey``) re-enables
    /// automatic checks and upgrades the legacy 24h interval to ``scheduledCheckInterval`` for
    /// installs that predate the embedded defaults.
    public func apply(to defaults: UserDefaults) {
        defaults.register(defaults: [
            Self.automaticChecksKey: true,
            Self.automaticallyUpdateKey: false,
            Self.scheduledCheckIntervalKey: scheduledCheckInterval,
            Self.sendProfileInfoKey: false,
        ])

        guard !defaults.bool(forKey: Self.migrationKey) else { return }

        // Repair older installs that may have ended up with automatic checks disabled
        // before the updater defaults were embedded in Info.plist.
        defaults.set(true, forKey: Self.automaticChecksKey)

        if let interval = defaults.object(forKey: Self.scheduledCheckIntervalKey) as? NSNumber {
            let currentInterval = interval.doubleValue
            if currentInterval <= 0 ||
                abs(currentInterval - previousDefaultScheduledCheckInterval) < 1 {
                defaults.set(scheduledCheckInterval, forKey: Self.scheduledCheckIntervalKey)
            }
        } else {
            defaults.set(scheduledCheckInterval, forKey: Self.scheduledCheckIntervalKey)
        }

        if defaults.object(forKey: Self.automaticallyUpdateKey) == nil {
            defaults.set(false, forKey: Self.automaticallyUpdateKey)
        }
        if defaults.object(forKey: Self.sendProfileInfoKey) == nil {
            defaults.set(false, forKey: Self.sendProfileInfoKey)
        }

        defaults.set(true, forKey: Self.migrationKey)
    }
}
