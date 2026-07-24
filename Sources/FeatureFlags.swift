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
/// Resolution semantics (flags must never break the app):
/// - A remote value is authoritative when present, so rollout and kill-switch
///   changes cannot be masked by a stale local override.
/// - Without a remote value — including forever, when the SDK never starts
///   because telemetry is off or a DEBUG build lacks CMUX_POSTHOG_ENABLE=1 —
///   a local override applies, followed by the explicit per-flag default.
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
    private static let workspaceTodoControlsDefault = false
    private static let appKitSidebarListDefault = true

    private static let overrideKeyPrefix = "cmux.flags.override."

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
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
            // Renders the workspace sidebar with the AppKit NSTableView list
            // (virtualized rows, measured-once heights) instead of the SwiftUI
            // LazyVStack. On by default after the remote rollout reached 100%.
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

    var isWorkspaceTodoControlsEnabled: Bool {
        effectiveValue(for: Self.allFlags[5])
    }

    var isAppKitSidebarListEnabled: Bool {
        effectiveValue(for: Self.allFlags[6])
    }

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let remoteFlagValueProvider: (String) -> Any?
    @ObservationIgnored
    private var flagsObserver: (any NSObjectProtocol)?

    private var localOverridesByKey: [String: Bool] = [:]
    private var remoteValuesByKey: [String: Bool] = [:]
    private var resolutionsByKey: [String: CmuxFeatureFlagResolution] = [:]

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
    /// the SDK never sets up — flags then keep their local fallback resolution.
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
        resolution(for: definition).effectiveValue
    }

    func resolution(for definition: CmuxFeatureFlagDefinition) -> CmuxFeatureFlagResolution {
        resolutionsByKey[definition.key] ?? CmuxFeatureFlagResolution(
            remoteValue: remoteValuesByKey[definition.key],
            overrideValue: localOverridesByKey[definition.key],
            defaultValue: definition.defaultWhenUnavailable
        )
    }

    func overrideValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        localOverridesByKey[definition.key]
    }

    func remoteValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        remoteValuesByKey[definition.key]
    }

    func setOverride(_ value: Bool?, for definition: CmuxFeatureFlagDefinition) {
        guard value == nil || remoteValuesByKey[definition.key] == nil else { return }

        let previousResolutions = resolutionsByKey
        if let value {
            localOverridesByKey[definition.key] = value
            defaults.set(value, forKey: Self.overrideDefaultsKey(for: definition.key))
        } else {
            localOverridesByKey.removeValue(forKey: definition.key)
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    func clearAllOverrides() {
        let previousResolutions = resolutionsByKey
        var clearedAnyOverride = false
        for definition in Self.allFlags {
            if localOverridesByKey.removeValue(forKey: definition.key) != nil {
                clearedAnyOverride = true
            }
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        guard clearedAnyOverride else { return }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    func applyLoadedFlags() {
        let previousResolutions = resolutionsByKey
        remoteValuesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.coerceBoolFlagValue(remoteFlagValueProvider(definition.key)) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    private func recomputeEffectiveValues() {
        resolutionsByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            values[definition.key] = CmuxFeatureFlagResolution(
                remoteValue: remoteValuesByKey[definition.key],
                overrideValue: localOverridesByKey[definition.key],
                defaultValue: definition.defaultWhenUnavailable
            )
        }
    }

    private func postChangeIfNeeded(previousResolutions: [String: CmuxFeatureFlagResolution]) {
        if previousResolutions != resolutionsByKey {
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
