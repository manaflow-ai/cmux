import CmuxSettings
import Foundation
import UserNotifications

extension NotificationSoundSettings {
    /// Caches the last validated matrix off the main actor. The raw JSON is
    /// the invalidation token, so a settings write automatically selects a new
    /// snapshot without a second observation channel.
    private actor OverrideSnapshotCache {
        private var cachedRawValue: String?
        private var cachedOverrides: NotificationSoundOverrides?

        func overrides(for rawValue: String?) -> NotificationSoundOverrides? {
            guard let rawValue, !rawValue.isEmpty else {
                cachedRawValue = rawValue
                cachedOverrides = .empty
                return .empty
            }
            guard rawValue.utf8.count <= NotificationSoundOverrides.maximumJSONBytes else {
                cachedRawValue = rawValue
                cachedOverrides = nil
                return nil
            }
            if rawValue == cachedRawValue {
                return cachedOverrides
            }
            let decoded = NotificationSoundOverrides(jsonString: rawValue)
            cachedRawValue = rawValue
            cachedOverrides = decoded
            return decoded
        }
    }

    private static let overrideSnapshotCache = OverrideSnapshotCache()

    /// Captures global and optional matrix settings before asynchronous preparation.
    static func resolutionSnapshot(
        context: NotificationSoundOverrideContext?,
        defaults: UserDefaults = .standard
    ) -> NotificationSoundResolutionSnapshot {
        let globalSelection = ResolvedNotificationSoundPlaybackSelection(
            value: defaults.string(forKey: key) ?? defaultValue,
            customFilePath: defaults.string(forKey: customFilePathKey)
        )
        let overrides = configuredOverrides(
            rawValue: defaults.string(
                forKey: NotificationsCatalogSection().soundOverrides.userDefaultsKey
            )
        )
        return makeResolutionSnapshot(
            context: context,
            globalSelection: globalSelection,
            overrides: overrides
        )
    }

    /// Captures settings synchronously, then decodes the matrix on the cache
    /// actor. Callers that are already on the main actor use this path so JSON
    /// parsing never occupies the UI executor.
    static func cachedResolutionSnapshot(
        context: NotificationSoundOverrideContext?,
        defaults: UserDefaults
    ) async -> NotificationSoundResolutionSnapshot {
        let globalSelection = ResolvedNotificationSoundPlaybackSelection(
            value: defaults.string(forKey: key) ?? defaultValue,
            customFilePath: defaults.string(forKey: customFilePathKey)
        )
        let rawOverrides = defaults.string(
            forKey: NotificationsCatalogSection().soundOverrides.userDefaultsKey
        )
        let overrides = await overrideSnapshotCache.overrides(for: rawOverrides)
        return makeResolutionSnapshot(
            context: context,
            globalSelection: globalSelection,
            overrides: overrides
        )
    }

    private static func makeResolutionSnapshot(
        context: NotificationSoundOverrideContext?,
        globalSelection: ResolvedNotificationSoundPlaybackSelection,
        overrides: NotificationSoundOverrides?
    ) -> NotificationSoundResolutionSnapshot {
        guard let context,
              let overrides,
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
        let snapshot = await cachedResolutionSnapshot(
            context: context,
            defaults: defaults
        )
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

    private static func configuredOverrides(rawValue: String?) -> NotificationSoundOverrides? {
        guard let rawValue, !rawValue.isEmpty else {
            return .empty
        }
        guard rawValue.utf8.count <= NotificationSoundOverrides.maximumJSONBytes else {
            return nil
        }
        return NotificationSoundOverrides(jsonString: rawValue)
    }
}
