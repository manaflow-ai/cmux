import Foundation
import Observation
import PostHog

struct CmuxFeatureFlagDefinition: Identifiable, Equatable {
    var id: String { key }

    let key: String
    let title: String
    let flagDescription: String
    let defaultWhenUnavailable: Bool
}

/// PostHog-backed runtime feature flags for the macOS app (PostHog project
/// 244066, same public key analytics uses). Values are cached in memory and
/// refreshed when the SDK reports a flag payload, so gated UI can be toggled
/// from the PostHog dashboard without shipping a build.
///
/// Fallback semantics (flags must never break the app):
/// - Until a payload arrives — including forever, when the SDK never starts
///   because telemetry is off or a DEBUG build lacks CMUX_POSTHOG_ENABLE=1 —
///   every flag keeps its safe default.
/// - Once a payload has arrived, a false flag reads as off. An absent flag
///   still uses the explicit per-flag fallback below.
///
/// Registry contract (enforced by scripts/lint-feature-flags.py in CI): each
/// flag declares key / owner / reviewBy / defaultWhenUnavailable in the FLAG
/// comment above its property, and its key literal appears nowhere else.
@MainActor
@Observable
final class CmuxFeatureFlags {
    static let shared = CmuxFeatureFlags()

    #if DEBUG
    private static let proUpgradeUIDefault = true
    #else
    private static let proUpgradeUIDefault = false
    #endif

    private static let mobileConnectButtonDefault = true
    private static let overrideKeyPrefix = "cmux.flags.override."

    // Order is load-bearing for the typed accessors below. A keyed lookup would
    // repeat flag-key literals and violate the feature-flag lint's single
    // evaluation-site rule.
    static var allFlags: [CmuxFeatureFlagDefinition] {
        [
            // FLAG(key: pro-upgrade-ui-enabled-release, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
            // Shows the Pro upgrade entrypoints (sidebar badge, Settings Account
            // card, palette command, Help menu item). Release builds hide them until
            // the PostHog flag is enabled; DEBUG keeps them visible for dogfood.
            CmuxFeatureFlagDefinition(
                key: "pro-upgrade-ui-enabled-release",
                title: String(localized: "featureFlags.proUpgrade.title", defaultValue: "Pro upgrade UI"),
                flagDescription: String(
                    localized: "featureFlags.proUpgrade.description",
                    defaultValue: "Shows Pro upgrade entrypoints in the sidebar, Settings, command palette, and Help menu."
                ),
                defaultWhenUnavailable: Self.proUpgradeUIDefault
            ),

            // FLAG(key: mobile-connect-button-enabled-release, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
            // Shows the top-right iPhone button that opens the Mobile Connect
            // (phone pairing) window. Default keeps it visible when flags are
            // unavailable; the window it opens ships in every build.
            CmuxFeatureFlagDefinition(
                key: "mobile-connect-button-enabled-release",
                title: String(localized: "featureFlags.mobileConnect.title", defaultValue: "Mobile Connect button"),
                flagDescription: String(
                    localized: "featureFlags.mobileConnect.description",
                    defaultValue: "Shows the iPhone button that opens the Mobile Connect pairing window."
                ),
                defaultWhenUnavailable: Self.mobileConnectButtonDefault
            ),
        ]
    }

    var isProUpgradeUIEnabled: Bool {
        effectiveValue(for: Self.allFlags[0])
    }

    var isMobileConnectButtonEnabled: Bool {
        effectiveValue(for: Self.allFlags[1])
    }

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let remoteFlagValueProvider: (String) -> Any?
    @ObservationIgnored
    private var flagsObserver: (any NSObjectProtocol)?

    private var localOverridesByKey: [String: Bool] = [:]
    private var remoteValuesByKey: [String: Bool] = [:]
    private var effectiveValuesByKey: [String: Bool] = [:]

    init(
        defaults: UserDefaults = .standard,
        remoteFlagValueProvider: @escaping (String) -> Any? = { PostHogSDK.shared.getFeatureFlag($0) }
    ) {
        self.defaults = defaults
        self.remoteFlagValueProvider = remoteFlagValueProvider
        localOverridesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.storedOverrideValue(for: definition.key, defaults: defaults) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
    }

    /// Called once from AppDelegate after PostHog analytics starts. Safe when
    /// the SDK never sets up — flags then keep their defaults.
    func start() {
        guard flagsObserver == nil else { return }
        flagsObserver = NotificationCenter.default.addObserver(
            forName: PostHogSDK.didReceiveFeatureFlags,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyLoadedFlags()
            }
        }
        PostHogSDK.shared.reloadFeatureFlags()
    }

    func effectiveValue(for definition: CmuxFeatureFlagDefinition) -> Bool {
        effectiveValuesByKey[definition.key] ?? definition.defaultWhenUnavailable
    }

    func overrideValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        localOverridesByKey[definition.key]
    }

    func remoteValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        remoteValuesByKey[definition.key]
    }

    func setOverride(_ value: Bool?, for definition: CmuxFeatureFlagDefinition) {
        let previousEffectiveValues = effectiveValuesByKey
        if let value {
            localOverridesByKey[definition.key] = value
            defaults.set(value, forKey: Self.overrideDefaultsKey(for: definition.key))
        } else {
            localOverridesByKey.removeValue(forKey: definition.key)
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousEffectiveValues: previousEffectiveValues)
    }

    func clearAllOverrides() {
        let previousEffectiveValues = effectiveValuesByKey
        var clearedAnyOverride = false
        for definition in Self.allFlags {
            if localOverridesByKey.removeValue(forKey: definition.key) != nil {
                clearedAnyOverride = true
            }
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        guard clearedAnyOverride else { return }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousEffectiveValues: previousEffectiveValues)
    }

    func applyLoadedFlags() {
        let previousEffectiveValues = effectiveValuesByKey
        remoteValuesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.coerceBoolFlagValue(remoteFlagValueProvider(definition.key)) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousEffectiveValues: previousEffectiveValues)
    }

    private func recomputeEffectiveValues() {
        effectiveValuesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            values[definition.key] = localOverridesByKey[definition.key]
                ?? remoteValuesByKey[definition.key]
                ?? definition.defaultWhenUnavailable
        }
    }

    private func postChangeIfNeeded(previousEffectiveValues: [String: Bool]) {
        if Self.allFlags.contains(where: { definition in
            previousEffectiveValues[definition.key] != effectiveValuesByKey[definition.key]
        }) {
            NotificationCenter.default.post(name: .cmuxFeatureFlagsDidChange, object: self)
        }
    }

    private static func overrideDefaultsKey(for key: String) -> String {
        overrideKeyPrefix + key
    }

    private static func storedOverrideValue(for key: String, defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: overrideDefaultsKey(for: key)) else {
            return nil
        }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return nil
    }

    nonisolated static func coerceBoolFlagValue(_ value: Any?, default fallback: Bool) -> Bool {
        coerceBoolFlagValue(value) ?? fallback
    }

    nonisolated static func coerceBoolFlagValue(_ value: Any?) -> Bool? {
        guard let value else { return nil }

        if let boolValue = value as? Bool {
            return boolValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }

        if let stringValue = value as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }

        return nil
    }
}

extension Notification.Name {
    static let cmuxFeatureFlagsDidChange = Notification.Name("cmuxFeatureFlagsDidChange")
}
