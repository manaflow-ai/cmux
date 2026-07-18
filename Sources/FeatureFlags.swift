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
/// - Until a payload arrives, the last remote value survives restarts. A flag
///   that has never loaded keeps its safe default.
/// - Cached disables remain authoritative when a later refresh omits a flag,
///   preserving remote kill switches through outages. Cached enables are
///   cleared when omitted so default-off features cannot remain enabled after
///   their remote flag is removed.
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

    #if DEBUG
    private static let cloudVMUIDefault = true
    #else
    private static let cloudVMUIDefault = false
    #endif
    private static let agentChatUIDefault = false
    private static let sidebarWorkspaceAgentSpinnerDefault = false
    private static let simulatorDefault = true
    private static let workspaceTodoControlsDefault = false
    private static let appKitSidebarListDefault = false

    private static let overrideKeyPrefix = "cmux.flags.override."
    private static let remoteCacheKeyPrefix = "cmux.flags.remote."

    // Order is load-bearing for the typed accessors below. A keyed lookup would
    // repeat flag-key literals and violate the feature-flag lint's single
    // evaluation-site rule.
    static let allFlags: [CmuxFeatureFlagDefinition] = {
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
                defaultWhenUnavailable: CmuxFeatureFlags.proUpgradeUIDefault
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
                defaultWhenUnavailable: CmuxFeatureFlags.mobileConnectButtonDefault
            ),

            // FLAG(key: cloud-vm-ui-enabled-release, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
            // Shows the Cloud VM entrypoints: the new-workspace dropdown section
            // (Open/Fork/Checkpoint/Restore/Advanced), the caret's direct Cloud
            // VM menu, and the command-palette Cloud VM commands. Release builds
            // hide them until the PostHog flag is enabled; DEBUG keeps them
            // visible for dogfood.
            CmuxFeatureFlagDefinition(
                key: "cloud-vm-ui-enabled-release",
                title: String(localized: "featureFlags.cloudVM.title", defaultValue: "Cloud VM UI"),
                flagDescription: String(
                    localized: "featureFlags.cloudVM.description",
                    defaultValue: "Shows Cloud VM entrypoints in the new-workspace dropdown and command palette."
                ),
                defaultWhenUnavailable: CmuxFeatureFlags.cloudVMUIDefault
            ),

            // FLAG(key: agent-chat-ui-enabled-release, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
            // Shows the Agent Chat entrypoints: the new-workspace dropdown item,
            // command-palette command, surface-tab-bar button, and shared action
            // executor. Hidden by default until the sidecar UX is ready to ship.
            CmuxFeatureFlagDefinition(
                key: "agent-chat-ui-enabled-release",
                title: String(localized: "featureFlags.agentChat.title", defaultValue: "Agent Chat UI"),
                flagDescription: String(
                    localized: "featureFlags.agentChat.description",
                    defaultValue: "Shows Agent Chat entrypoints in the new-workspace dropdown, command palette, and surface tab bar."
                ),
                defaultWhenUnavailable: CmuxFeatureFlags.agentChatUIDefault
            ),

            // FLAG(key: sidebar-workspace-agent-spinner-experiment, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
            // Shows the coding-agent activity spinner in workspace rows. Hidden
            // by default while multi-agent lifecycle edge cases are investigated.
            CmuxFeatureFlagDefinition(
                key: "sidebar-workspace-agent-spinner-experiment",
                title: String(
                    localized: "featureFlags.sidebarWorkspaceAgentSpinner.title",
                    defaultValue: "Workspace agent spinner"
                ),
                flagDescription: String(
                    localized: "featureFlags.sidebarWorkspaceAgentSpinner.description",
                    defaultValue: "Shows a spinner in workspace rows while coding agents are running."
                ),
                defaultWhenUnavailable: CmuxFeatureFlags.sidebarWorkspaceAgentSpinnerDefault
            ),

            // FLAG(key: simulator-enabled-release, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
            // Controls every Simulator entrypoint and active pane. The enabled
            // fallback preserves access when PostHog is unavailable, while the
            // remote value provides a release kill switch.
            CmuxFeatureFlagDefinition(
                key: "simulator-enabled-release",
                title: String(
                    localized: "featureFlags.simulator.title",
                    defaultValue: "Simulator"
                ),
                flagDescription: String(
                    localized: "featureFlags.simulator.description",
                    defaultValue: "Enables iPhone and iPad Simulator panes, commands, and automation."
                ),
                defaultWhenUnavailable: CmuxFeatureFlags.simulatorDefault
            ),

            // FLAG(key: workspace-todo-controls-enabled-release, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
            // Shows user-facing workspace todo controls that create checklist
            // items or set completion/status lanes. Hidden until the local
            // beta setting opts in or the PostHog flag is enabled.
            CmuxFeatureFlagDefinition(
                key: "workspace-todo-controls-enabled-release",
                title: String(
                    localized: "featureFlags.workspaceTodoControls.title",
                    defaultValue: "Workspace todo controls"
                ),
                flagDescription: String(
                    localized: "featureFlags.workspaceTodoControls.description",
                    defaultValue: "Shows Add Checklist Item and workspace completion status controls."
                ),
                defaultWhenUnavailable: CmuxFeatureFlags.workspaceTodoControlsDefault
            ),

            // FLAG(key: sidebar-appkit-list-experiment, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
            // Renders the workspace sidebar with the AppKit NSTableView list
            // (virtualized rows, measured-once heights) instead of the SwiftUI
            // LazyVStack. Off by default while the rewrite soaks.
            CmuxFeatureFlagDefinition(
                key: "sidebar-appkit-list-experiment",
                title: String(
                    localized: "featureFlags.appKitSidebarList.title",
                    defaultValue: "Lawrence Sidebar"
                ),
                flagDescription: String(
                    localized: "featureFlags.appKitSidebarList.description",
                    defaultValue: "Renders the workspace sidebar with a native AppKit list and divider for smoother scrolling and resizing with many workspaces."
                ),
                defaultWhenUnavailable: CmuxFeatureFlags.appKitSidebarListDefault
            ),
        ]
    }()

    var isProUpgradeUIEnabled: Bool {
        effectiveValue(for: Self.allFlags[0])
    }

    var isMobileConnectButtonEnabled: Bool {
        effectiveValue(for: Self.allFlags[1])
    }

    var isCloudVMUIEnabled: Bool {
        effectiveValue(for: Self.allFlags[2])
    }

    var isAgentChatUIEnabled: Bool {
        effectiveValue(for: Self.allFlags[3])
    }

    var isSidebarWorkspaceAgentSpinnerEnabled: Bool {
        effectiveValue(for: Self.allFlags[4])
    }

    var isSimulatorEnabled: Bool {
        effectiveValue(for: Self.allFlags[5])
    }

    var isWorkspaceTodoControlsEnabled: Bool {
        effectiveValue(for: Self.allFlags[6])
    }

    var isAppKitSidebarListEnabled: Bool {
        effectiveValue(for: Self.allFlags[7])
    }

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let remoteFlagValueProvider: (String) -> Any?
    @ObservationIgnored
    private let remoteFlagLoader: @Sendable () async -> [String: Bool]?
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var refreshTimer: Timer?

    private var localOverridesByKey: [String: Bool] = [:]
    private var remoteValuesByKey: [String: Bool] = [:]
    private var effectiveValuesByKey: [String: Bool] = [:]

    init(
        defaults: UserDefaults = .standard,
        remoteFlagValueProvider: @escaping (String) -> Any? = { PostHogSDK.shared.getFeatureFlag($0) },
        remoteFlagLoader: @escaping @Sendable () async -> [String: Bool]? = {
            await CmuxFeatureFlags.loadPostHogControlPlaneFlags()
        }
    ) {
        self.defaults = defaults
        self.remoteFlagValueProvider = remoteFlagValueProvider
        self.remoteFlagLoader = remoteFlagLoader
        localOverridesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.storedOverrideValue(for: definition.key, defaults: defaults) {
                values[definition.key] = value
            }
        }
        remoteValuesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.storedBoolValue(
                forKey: Self.remoteCacheKey(for: definition.key),
                defaults: defaults
            ) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
    }

    /// Loads release-control values without initializing analytics. The request
    /// uses one product-wide identifier, so it cannot correlate an installation
    /// or reuse PostHog's analytics identity.
    func start() {
        guard refreshTimer == nil else { return }
        refreshRemoteFlags()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRemoteFlags() }
        }
    }

    private func refreshRemoteFlags() {
        guard refreshTask == nil else { return }
        let loader = remoteFlagLoader
        refreshTask = Task { @MainActor [weak self] in
            let values = await loader()
            guard let self else { return }
            self.refreshTask = nil
            guard let values, !Task.isCancelled else { return }
            self.applyRemoteFlagValues(values)
        }
    }

    private func applyRemoteFlagValues(_ values: [String: Bool]) {
        let previousEffectiveValues = effectiveValuesByKey
        for definition in Self.allFlags {
            if let value = values[definition.key] {
                remoteValuesByKey[definition.key] = value
                defaults.set(value, forKey: Self.remoteCacheKey(for: definition.key))
            } else if remoteValuesByKey[definition.key] == true {
                remoteValuesByKey.removeValue(forKey: definition.key)
                defaults.removeObject(forKey: Self.remoteCacheKey(for: definition.key))
            }
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousEffectiveValues: previousEffectiveValues)
    }

    nonisolated static func postHogControlPlaneRequest() -> URLRequest? {
        guard let url = URL(string: "https://cmux.com/api/client-config") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "distinctId": "cmux-desktop-release-control",
            "context": [:],
        ])
        return request
    }

    nonisolated private static func loadPostHogControlPlaneFlags() async -> [String: Bool]? {
        guard let request = postHogControlPlaneRequest() else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              data.count <= 1_048_576,
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let values = object["featureFlags"] as? [String: Any] else { return nil }
        return values.reduce(into: [String: Bool]()) { result, entry in
            if let value = entry.value as? Bool {
                result[entry.key] = value
            } else if let value = entry.value as? NSNumber {
                result[entry.key] = value.boolValue
            } else if let value = entry.value as? String {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes", "on": result[entry.key] = true
                case "false", "0", "no", "off": result[entry.key] = false
                default: break
                }
            }
        }
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
        for definition in Self.allFlags {
            if let value = Self.coerceBoolFlagValue(remoteFlagValueProvider(definition.key)) {
                remoteValuesByKey[definition.key] = value
                defaults.set(value, forKey: Self.remoteCacheKey(for: definition.key))
            } else if remoteValuesByKey[definition.key] == true {
                remoteValuesByKey.removeValue(forKey: definition.key)
                defaults.removeObject(forKey: Self.remoteCacheKey(for: definition.key))
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

    private static func remoteCacheKey(for key: String) -> String {
        remoteCacheKeyPrefix + key
    }

    private static func storedOverrideValue(for key: String, defaults: UserDefaults) -> Bool? {
        storedBoolValue(forKey: overrideDefaultsKey(for: key), defaults: defaults)
    }

    private static func storedBoolValue(forKey key: String, defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: key) else {
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
