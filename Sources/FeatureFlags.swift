import Foundation
import Observation
import PostHog
import os

struct CmuxFeatureFlagDefinition: Identifiable, Equatable, Sendable {
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
/// - Without a remote value, a local override applies, followed by the explicit
///   per-flag default.
/// - Until a payload arrives, the last remote value survives restarts. A flag
///   that has never loaded keeps its safe default.
/// - Request and payload failures preserve the complete cached snapshot. A
///   successfully parsed payload replaces it, so omitted flags return to their
///   local override or default.
///
/// Registry contract (enforced by scripts/lint-feature-flags.py in CI): each
/// flag declares key / owner / reviewBy / defaultWhenUnavailable in the FLAG
/// comment above its property, and its key literal appears nowhere else.
@MainActor
@Observable
final class CmuxFeatureFlags {
    static let shared = CmuxFeatureFlags(publishesOffMainSnapshot: true)

    #if DEBUG
    private static let proUpgradeUIDefault = true
    #else
    private static let proUpgradeUIDefault = false
    #endif

    private static let mobileConnectButtonDefault = false
    private static let sidebarAccountButtonDefault = true

    #if DEBUG
    private nonisolated static let cloudVMUIDefault = true
    #else
    private nonisolated static let cloudVMUIDefault = false
    #endif
    private static let agentChatUIDefault = false
    #if DEBUG
    private nonisolated static let mobileWorkspaceChangesDefault = true
    #else
    private nonisolated static let mobileWorkspaceChangesDefault = false
    #endif
    private static let sidebarWorkspaceAgentSpinnerDefault = false
    private nonisolated static let simulatorDefault = true
    private static let workspaceTodoControlsDefault = false
    private static let appKitSidebarListDefault = true
    private static let mobileTerminalFilesChipDefault = true
    private nonisolated static let mobileTaskComposerDefault = true

    private static let overrideKeyPrefix = "cmux.flags.override."
    private static let remoteCacheKeyPrefix = "cmux.flags.remote."
    private static let releaseControlProductWideDistinctID = "cmux-desktop-release-control"
    private static let releaseControlDistinctIDKey = "cmux.flags.releaseControlDistinctID"
    private static let releaseControlDistinctIDPrefix =
        releaseControlProductWideDistinctID + "-"
    private nonisolated static let maximumPostHogControlPlaneResponseBytes = 1_048_576

    // FLAG(key: sidebar-appkit-list-experiment, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
    // Renders the workspace sidebar with the AppKit NSTableView list
    // (virtualized rows, measured-once heights) instead of the SwiftUI
    // LazyVStack. On by default after the remote rollout reached 100%.
    static let appKitSidebarListFlag = CmuxFeatureFlagDefinition(
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
    )

    // FLAG(key: mobile-workspace-changes-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
    // Serves the iOS diff viewer: advertises workspace.changes.v1 to phones
    // and answers the mobile.workspace.changes.* RPCs behind it. Every iOS
    // entry point (workspace-row chip, toolbar button, one-time hint, Changes
    // sheet, summary polling) feature-detects on that capability, so this one
    // Mac-side flag turns the whole feature off end to end. Release builds
    // keep it off until the PostHog flag enables it; DEBUG keeps it on for
    // dogfood.
    nonisolated static let mobileWorkspaceChangesFlag = CmuxFeatureFlagDefinition(
        key: "mobile-workspace-changes-enabled-release",
        title: String(
            localized: "featureFlags.mobileWorkspaceChanges.title",
            defaultValue: "Mobile diff viewer"
        ),
        flagDescription: String(
            localized: "featureFlags.mobileWorkspaceChanges.description",
            defaultValue: "Serves workspace diffs to paired phones: the iOS changes chip, toolbar button, and Changes sheet."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.mobileWorkspaceChangesDefault
    )

    // FLAG(key: ios-artifact-chip-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2027-02-01, defaultWhenUnavailable: true)
    // Controls the fully integrated terminal Files chip on iOS. The enabled
    // fallback preserves the shipping behavior when PostHog is unavailable;
    // a remote false value is the emergency kill switch.
    static let mobileTerminalFilesChipFlag = CmuxFeatureFlagDefinition(
        key: "ios-artifact-chip-enabled-release",
        title: String(
            localized: "featureFlags.mobileTerminalFilesChip.title",
            defaultValue: "Mobile terminal Files chip"
        ),
        flagDescription: String(
            localized: "featureFlags.mobileTerminalFilesChip.description",
            defaultValue: "Shows the Files chip over iOS terminals and runs its visible-path count scan."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.mobileTerminalFilesChipDefault
    )

    // FLAG(key: simulator-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
    // Controls every Simulator entrypoint and active pane. The enabled
    // fallback preserves access when PostHog is unavailable, while the
    // remote value provides a release kill switch. Declared nonisolated so
    // the mobile host's off-main capability list can gate the advertised
    // simulator capabilities on the same flag as RPC dispatch.
    // FLAG(key: cloud-vm-ui-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
    // Shows the Cloud VM entrypoints: the new-workspace dropdown section
    // (Open/Fork/Checkpoint/Restore/Advanced), the caret's direct Cloud
    // VM menu, the command-palette Cloud VM commands, and the right-sidebar
    // Machines tab. Release builds hide them until the PostHog flag is
    // enabled; DEBUG keeps them visible for dogfood. Declared nonisolated so
    // off-main readers (right-sidebar mode availability) can consult the
    // published snapshot.
    nonisolated static let cloudVMUIFlag = CmuxFeatureFlagDefinition(
        key: "cloud-vm-ui-enabled-release",
        title: String(localized: "featureFlags.cloudVM.title", defaultValue: "Cloud VM UI"),
        flagDescription: String(
            localized: "featureFlags.cloudVM.description",
            defaultValue: "Shows Cloud VM entrypoints in the new-workspace dropdown and command palette."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.cloudVMUIDefault
    )

    nonisolated static let simulatorFlag = CmuxFeatureFlagDefinition(
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
    )

    // FLAG(key: mobile-task-composer-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
    // Controls the iOS Task Composer from the Mac host. When off, the Mac stops
    // advertising task-create/model/directory/attachment capabilities and
    // task-specific RPCs fail with capability_disabled, so paired phones hide
    // the composer without needing a user-visible Beta toggle.
    nonisolated static let mobileTaskComposerFlag = CmuxFeatureFlagDefinition(
        key: "mobile-task-composer-enabled-release",
        title: String(
            localized: "featureFlags.mobileTaskComposer.title",
            defaultValue: "Mobile Task Composer"
        ),
        flagDescription: String(
            localized: "featureFlags.mobileTaskComposer.description",
            defaultValue: "Enables the iOS New Task composer, including task model discovery, directory picking, and attachment staging."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.mobileTaskComposerDefault
    )

    // Order is load-bearing for the positional typed accessors below. Flags
    // that need a stable public definition are declared independently and
    // included here without repeating their key literal.
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
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
            // Shows the bottom-left sidebar iPhone button that opens the Tailscale
            // Pairing workspace. It stays hidden until the remote flag or a
            // local debug override enables it.
            CmuxFeatureFlagDefinition(
                key: "mobile-connect-button-enabled-release",
                title: String(localized: "featureFlags.mobileConnect.title", defaultValue: "Tailscale Pairing button"),
                flagDescription: String(
                    localized: "featureFlags.mobileConnect.description",
                    defaultValue: "Shows the Tailscale Pairing button in the sidebar footer."
                ),
                defaultWhenUnavailable: CmuxFeatureFlags.mobileConnectButtonDefault
            ),

            // FLAG(key: sidebar-account-button-enabled-release, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
            // Shows the account control in the bottom-left sidebar footer. The
            // Settings account section remains available when this shortcut is off.
            CmuxFeatureFlagDefinition(
                key: "sidebar-account-button-enabled-release",
                title: String(localized: "featureFlags.sidebarAccount.title", defaultValue: "Sidebar account button"),
                flagDescription: String(
                    localized: "featureFlags.sidebarAccount.description",
                    defaultValue: "Shows the profile and sign-in control in the sidebar footer."
                ),
                defaultWhenUnavailable: CmuxFeatureFlags.sidebarAccountButtonDefault
            ),

            CmuxFeatureFlags.cloudVMUIFlag,

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

            CmuxFeatureFlags.simulatorFlag,

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

            CmuxFeatureFlags.appKitSidebarListFlag,

            CmuxFeatureFlags.mobileWorkspaceChangesFlag,

            CmuxFeatureFlags.mobileTerminalFilesChipFlag,
            CmuxFeatureFlags.mobileTaskComposerFlag,
        ]
    }()

    var isProUpgradeUIEnabled: Bool {
        effectiveValue(for: Self.allFlags[0])
    }

    var isMobileConnectButtonEnabled: Bool {
        effectiveValue(for: Self.allFlags[1])
    }

    var isCloudVMUIEnabled: Bool {
        effectiveValue(for: Self.cloudVMUIFlag)
    }

    /// Mirror of ``isCloudVMUIEnabled`` for nonisolated readers (right-sidebar
    /// mode availability). Reads the published off-main snapshot; before the
    /// shared instance publishes, it falls back to the compile-time default.
    nonisolated static var offMainIsCloudVMUIEnabled: Bool {
        offMainEffectiveValue(for: cloudVMUIFlag)
    }

    var isAgentChatUIEnabled: Bool {
        effectiveValue(for: Self.allFlags[4])
    }

    var isSidebarAccountButtonEnabled: Bool {
        effectiveValue(for: Self.allFlags[2])
    }

    var isSidebarWorkspaceAgentSpinnerEnabled: Bool {
        effectiveValue(for: Self.allFlags[5])
    }

    var isSimulatorEnabled: Bool {
        effectiveValue(for: Self.simulatorFlag)
    }

    var isWorkspaceTodoControlsEnabled: Bool {
        effectiveValue(for: Self.allFlags[7])
    }

    var isAppKitSidebarListEnabled: Bool {
        effectiveValue(for: Self.appKitSidebarListFlag)
    }

    var isMobileWorkspaceChangesEnabled: Bool {
        effectiveValue(for: Self.mobileWorkspaceChangesFlag)
    }

    var isMobileTerminalFilesChipEnabled: Bool {
        effectiveValue(for: Self.mobileTerminalFilesChipFlag)
    }

    var isMobileTaskComposerEnabled: Bool {
        effectiveValue(for: Self.mobileTaskComposerFlag)
    }

    /// Effective values mirrored for nonisolated readers: the mobile host
    /// serves status payloads (which carry the capability list) off the main
    /// actor. Written only by the shared instance so test instances cannot
    /// stomp process-wide state. Before the shared instance exists, readers
    /// get the per-flag compile-time default (fail-closed for release flags).
    private nonisolated static let offMainEffectiveValues = OSAllocatedUnfairLock(
        initialState: [String: Bool]()
    )

    nonisolated static func offMainEffectiveValue(
        for definition: CmuxFeatureFlagDefinition
    ) -> Bool {
        offMainEffectiveValues.withLock { $0[definition.key] }
            ?? definition.defaultWhenUnavailable
    }

    @ObservationIgnored
    private let publishesOffMainSnapshot: Bool
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
    private var resolutionsByKey: [String: CmuxFeatureFlagResolution] = [:]

    init(
        defaults: UserDefaults = .standard,
        telemetryEnabled: Bool = TelemetrySettings.enabledForCurrentLaunch,
        remoteFlagValueProvider: @escaping (String) -> Any? = { PostHogSDK.shared.getFeatureFlag($0) },
        remoteFlagLoader: (@Sendable () async -> [String: Bool]?)? = nil,
        publishesOffMainSnapshot: Bool = false
    ) {
        self.defaults = defaults
        self.publishesOffMainSnapshot = publishesOffMainSnapshot
        self.remoteFlagValueProvider = remoteFlagValueProvider
        if let remoteFlagLoader {
            self.remoteFlagLoader = remoteFlagLoader
        } else {
            let target = Self.releaseControlTarget(
                telemetryEnabled: telemetryEnabled,
                defaults: defaults
            )
            self.remoteFlagLoader = {
                await CmuxFeatureFlags.loadPostHogControlPlaneFlags(
                    distinctID: target.distinctID,
                    personProperties: target.personProperties
                )
            }
        }
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
    /// uses a separate anonymous installation identity only when telemetry is
    /// enabled. Opted-out launches use one product-wide ID without targeting
    /// properties, preserving a non-identifying emergency kill switch.
    func start() {
        guard refreshTimer == nil else { return }
        refreshRemoteFlags()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
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
        let previousResolutions = resolutionsByKey
        for definition in Self.allFlags {
            if let value = values[definition.key] {
                remoteValuesByKey[definition.key] = value
                defaults.set(value, forKey: Self.remoteCacheKey(for: definition.key))
            } else {
                remoteValuesByKey.removeValue(forKey: definition.key)
                defaults.removeObject(forKey: Self.remoteCacheKey(for: definition.key))
            }
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    static func postHogControlPlaneRequest(
        telemetryEnabled: Bool = TelemetrySettings.enabledForCurrentLaunch,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> URLRequest? {
        let target = releaseControlTarget(
            telemetryEnabled: telemetryEnabled,
            defaults: defaults,
            bundle: bundle
        )
        return postHogControlPlaneRequest(
            distinctID: target.distinctID,
            personProperties: target.personProperties
        )
    }

    private static func releaseControlTarget(
        telemetryEnabled: Bool,
        defaults: UserDefaults,
        bundle: Bundle = .main
    ) -> (distinctID: String, personProperties: [String: String]) {
        guard telemetryEnabled else {
            return (releaseControlProductWideDistinctID, [:])
        }
        return (
            releaseControlDistinctID(defaults: defaults),
            releaseControlPersonProperties(bundle: bundle)
        )
    }

    private static func releaseControlDistinctID(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: releaseControlDistinctIDKey),
           existing.hasPrefix(releaseControlDistinctIDPrefix),
           UUID(uuidString: String(existing.dropFirst(releaseControlDistinctIDPrefix.count))) != nil {
            return existing
        }
        let distinctID = releaseControlDistinctIDPrefix + UUID().uuidString.lowercased()
        defaults.set(distinctID, forKey: releaseControlDistinctIDKey)
        return distinctID
    }

    private static func releaseControlPersonProperties(
        bundle: Bundle = .main
    ) -> [String: String] {
        var properties = [
            "$os": "macOS",
            "cmux_architecture": releaseControlArchitecture,
        ]
        if let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String, !version.isEmpty {
            properties["$app_version"] = version
        }
        if let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String, !build.isEmpty {
            properties["$app_build"] = build
        }
        return properties
    }

    private static var releaseControlArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    nonisolated private static func postHogControlPlaneRequest(
        distinctID: String,
        personProperties: [String: String]
    ) -> URLRequest? {
        guard let url = URL(string: "https://cmux.com/api/client-config") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let context: [String: Any] = personProperties.isEmpty
            ? [:]
            : ["personProperties": personProperties]
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "distinctId": distinctID,
            "context": context,
        ])
        return request
    }

    nonisolated private static func loadPostHogControlPlaneFlags(
        distinctID: String,
        personProperties: [String: String]
    ) async -> [String: Bool]? {
        guard let request = postHogControlPlaneRequest(
            distinctID: distinctID,
            personProperties: personProperties
        ) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              response.expectedContentLength < 0
                || response.expectedContentLength <= maximumPostHogControlPlaneResponseBytes,
              let data = try? await boundedPostHogControlPlaneData(
                  from: bytes,
                  maximumByteCount: maximumPostHogControlPlaneResponseBytes
              )
        else { return nil }
        return postHogControlPlaneFlagValues(from: data)
    }

    nonisolated static func boundedPostHogControlPlaneData<Bytes: AsyncSequence>(
        from bytes: Bytes,
        maximumByteCount: Int
    ) async throws -> Data? where Bytes.Element == UInt8 {
        guard maximumByteCount >= 0 else { return nil }
        var data = Data()
        data.reserveCapacity(min(maximumByteCount, 16 * 1_024))
        for try await byte in bytes {
            guard data.count < maximumByteCount else { return nil }
            data.append(byte)
        }
        return data
    }

    nonisolated static func postHogControlPlaneFlagValues(
        from data: Data
    ) -> [String: Bool]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["errorsWhileComputingFlags"] as? Bool == false,
              let values = object["featureFlags"] as? [String: Any] else { return nil }
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
        if publishesOffMainSnapshot {
            let effectiveValues = resolutionsByKey.mapValues(\.effectiveValue)
            Self.offMainEffectiveValues.withLock { $0 = effectiveValues }
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
