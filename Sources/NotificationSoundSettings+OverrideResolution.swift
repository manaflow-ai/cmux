import CmuxSettings
import Foundation
import UserNotifications

extension NotificationSoundSettings {
    /// Captures global and optional matrix settings before asynchronous preparation.
    static func resolutionSnapshot(
        context: NotificationSoundOverrideContext?,
        defaults: UserDefaults = .standard
    ) -> NotificationSoundResolutionSnapshot {
        let globalSelection = ResolvedNotificationSoundPlaybackSelection(
            value: defaults.string(forKey: key) ?? defaultValue,
            customFilePath: defaults.string(forKey: customFilePathKey)
        )
        guard let context,
              let overrides = configuredOverrides(defaults: defaults),
              let soundOverride = overrides.override(
                  forAgentID: context.agentID,
                  alertType: context.alertType
              ) else {
            return NotificationSoundResolutionSnapshot(
                globalSelection: globalSelection,
                overrideSelection: nil
            )
        }
        return NotificationSoundResolutionSnapshot(
            globalSelection: globalSelection,
            overrideSelection: ResolvedNotificationSoundPlaybackSelection(
                value: soundOverride.sound,
                customFilePath: soundOverride.customSoundFilePath
            )
        )
    }

    /// Prepares a native notification sound without running file I/O on the main actor.
    @MainActor
    static func nativeNotificationSound(
        context: NotificationSoundOverrideContext?,
        defaults: UserDefaults = .standard,
        stagingDirectory: URL? = nil,
        pendingReferenceID: String? = nil
    ) async -> UNNotificationSound? {
        let snapshot = resolutionSnapshot(context: context, defaults: defaults)
        let prepared = await prepareNotificationSound(
            snapshot: snapshot,
            stagingDirectory: stagingDirectory,
            pendingReferenceID: pendingReferenceID
        )
        switch prepared {
        case .systemDefault:
            return .default
        case .silent:
            return nil
        case .named(let fileName):
            return UNNotificationSound(
                named: UNNotificationSoundName(rawValue: fileName)
            )
        }
    }

    private static func configuredOverrides(
        defaults: UserDefaults
    ) -> NotificationSoundOverrides? {
        let key = NotificationsCatalogSection().soundOverrides.userDefaultsKey
        guard let raw = defaults.string(forKey: key), !raw.isEmpty else {
            return .empty
        }
        return NotificationSoundOverrides(jsonString: raw)
    }
}
