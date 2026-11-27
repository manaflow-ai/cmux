public import CmuxNextSettings
import CmuxUpdater
public import Foundation

/// What decides whether the automatic updater runs now, as raw facts for `updates.status`'s
/// `automation`. Leo, 2026-11-27: "as in like us seeing a thing with the bottom elft sidebar the auto
/// update no longer being force paused". `cmux update status` (cmux-tui `cli/app/update_status.rs`)
/// decides from these whether automatic updates are paused and why; nothing here judges.
nonisolated public struct UpdateAutomationFacts: Sendable, Equatable {
    /// ``UpdaterService/pausesAutomaticUpdates`` (``AutomaticUpdatePause``): the build's own pause.
    public var pausedByBuild: Bool
    /// ``UpdaterService/configure`` ran: the person's update settings are applied.
    public var settingsApplied: Bool
    /// Sparkle's automatic check interval, nil while it checks only on a click.
    public var checkIntervalSeconds: TimeInterval?
    /// Sparkle's last check (scheduled, launch, wake or clicked), nil before the first.
    public var lastCheck: Date?
    /// The download setting as applied (`updates.automatic` download or idle), before the link and policy.
    public var downloadSetting: Bool
    /// `updates.meteredNetwork` (``UpdateMeteredMode``).
    public var meteredMode: String
    public var networkConstrained: Bool
    public var networkExpensive: Bool
    /// No path event yet: the link counts as metered until one arrives.
    public var networkPending: Bool
    public var downloadHeldForDeltas: Bool
    public var offManagedChannel: Bool
    public var managedPolicyDisables: Bool
    public var requiredMinimumVersion: String?
    /// Update When Idle's idle time, nil when it is off.
    public var installWhenIdleSeconds: TimeInterval?
    /// The feed's newest build for the followed ring at the last read (``UpdaterService/lastFeedRead``).
    public var feedNewest: String?
    public var feedReadAt: Date?
}

extension UpdaterService {
    /// The ``UpdateAutomationFacts`` of this updater now.
    var automationFacts: UpdateAutomationFacts {
        UpdateAutomationFacts(
            pausedByBuild: pausesAutomaticUpdates,
            settingsApplied: settingsApplied,
            checkIntervalSeconds: controller?.scheduledCheckInterval,
            lastCheck: controller?.lastUpdateCheckDate,
            downloadSetting: downloadSetting.enabled,
            meteredMode: downloadSetting.metered.rawValue,
            networkConstrained: network.constrained,
            networkExpensive: network.expensive,
            networkPending: networkPending,
            downloadHeldForDeltas: downloadHeldForDeltas,
            offManagedChannel: isOffManagedChannel,
            managedPolicyDisables: policy.disablesUpdates,
            requiredMinimumVersion: requiredMinimumVersion,
            installWhenIdleSeconds: installWhenIdle.map { Double($0.components.seconds) },
            feedNewest: lastFeedRead.flatMap { $0.ring == ring ? $0.newest : nil },
            feedReadAt: lastFeedRead.flatMap { $0.ring == ring ? $0.at : nil }
        )
    }
}

extension UpdateAutomationFacts {
    /// `updates.status`'s `automation`: raw facts; `cmux update status` decides paused and why from them.
    public var json: JSONValue {
        let date = { (date: Date?) in date.map { JSONValue.string(ISO8601DateFormatter().string(from: $0)) } ?? .null }
        let number = { (value: Double?) in value.map { JSONValue.number($0) } ?? .null }
        return .object([
            "paused_by_build": .bool(pausedByBuild),
            "settings_applied": .bool(settingsApplied),
            "check_interval_seconds": number(checkIntervalSeconds),
            "last_check": date(lastCheck),
            "download_setting": .bool(downloadSetting),
            "metered_mode": .string(meteredMode),
            "network_constrained": .bool(networkConstrained),
            "network_expensive": .bool(networkExpensive),
            "network_pending": .bool(networkPending),
            "download_held_for_deltas": .bool(downloadHeldForDeltas),
            "off_managed_channel": .bool(offManagedChannel),
            "managed_policy_disables": .bool(managedPolicyDisables),
            "required_minimum_version": requiredMinimumVersion.map(JSONValue.string) ?? .null,
            "install_when_idle_seconds": number(installWhenIdleSeconds),
            "feed_newest": feedNewest.map(JSONValue.string) ?? .null,
            "feed_read_at": date(feedReadAt),
        ])
    }
}
