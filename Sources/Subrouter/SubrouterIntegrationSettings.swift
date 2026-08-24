import Foundation
import CmuxSubrouter

/// Reads the subrouter integration settings from `UserDefaults` (the keys
/// declared in `CmuxSettings`' `SubrouterCatalogSection` and the sidebar
/// catalog) and assembles the store's ``SubrouterConfiguration``.
struct SubrouterIntegrationSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let enabledKey = "subrouterEnabled"
    static let endpointKey = "subrouterEndpoint"
    static let commandPathKey = "subrouterCommandPath"
    static let showAccountSwitcherKey = "sidebarShowAccountSwitcher"

    static let defaultEnabled = true
    static let defaultShowAccountSwitcher = true

    /// The effective gate: the subrouter feature flag
    /// (`CmuxFeatureFlags.isSubrouterUIEnabled`) controls rollout; the
    /// `subrouter.enabled` setting (default on) is the user's opt-out
    /// inside the flag.
    ///
    /// Reads the feature flag from ``CmuxFeatureFlags``' synchronized
    /// off-main snapshot, so mode-availability callers do not need a runtime
    /// `MainActor.assumeIsolated` precondition.
    var isEnabled: Bool {
        let flagEnabled = CmuxFeatureFlags.offMainEffectiveValue(for: CmuxFeatureFlags.subrouterUIFlag)
        return flagEnabled && userOptIn
    }

    /// The raw `subrouter.enabled` setting, without the feature flag.
    var userOptIn: Bool {
        guard defaults.object(forKey: Self.enabledKey) != nil else { return Self.defaultEnabled }
        return defaults.bool(forKey: Self.enabledKey)
    }

    /// Whether an explicit endpoint setting is syntactically valid. This
    /// cheap check lets sidebar availability fail closed before the runtime's
    /// off-main registry read completes, avoiding an indefinite spinner for a
    /// malformed endpoint.
    var hasValidEndpointSetting: Bool {
        let raw = (defaults.string(forKey: Self.endpointKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || SubrouterEndpoint(configurationString: raw) != nil
    }

    /// Whether the left-sidebar footer switcher should render: the master
    /// gate plus its own toggle.
    var showsAccountSwitcher: Bool {
        guard isEnabled else { return false }
        guard defaults.object(forKey: Self.showAccountSwitcherKey) != nil else {
            return Self.defaultShowAccountSwitcher
        }
        return defaults.bool(forKey: Self.showAccountSwitcherKey)
    }

    /// The store configuration derived from current defaults.
    ///
    /// Endpoint resolution mirrors the `sr` CLI so cmux always watches the
    /// daemon that is actually routing this machine's agents: an explicit
    /// `subrouter.endpoint` setting wins; otherwise `serverSelection` (the
    /// `sr server` default from `~/.subrouter/codex/servers.json`, loaded
    /// off-main by the caller via ``loadServerRegistryState()``);
    /// otherwise the local loopback daemon. An empty command path means
    /// resolve `sr` from `PATH`. Taking the selection as a parameter keeps
    /// this callable from hot notification paths (`UserDefaults` did-change
    /// fires on every defaults write) without any main-thread disk I/O.
    func currentConfiguration(
        serverSelection: SubrouterServerSelection.Server?,
        serverRegistryIsUnreadable: Bool = false
    ) -> SubrouterConfiguration {
        let endpointSetting = (defaults.string(forKey: endpointKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitEndpoint = SubrouterEndpoint(configurationString: endpointSetting)
        // Fail closed on a malformed explicit endpoint: a typo in an
        // intended remote address must never silently fall back to the
        // registry or the loopback daemon, where a local `sr switch` would
        // mutate credentials the user meant to manage remotely.
        let endpointSettingIsInvalid = !endpointSetting.isEmpty && explicitEndpoint == nil
        var serverName: String?
        var endpoint = explicitEndpoint
        if endpoint == nil, let server = serverSelection {
            endpoint = server.endpoint
            serverName = server.name
        }
        // Fail closed when the registry exists but cannot be read and
        // nothing else pins the endpoint: an unreadable registry may hide
        // a remote selection, so loopback must not be assumed.
        let registryBlocksConfiguration = serverRegistryIsUnreadable
            && explicitEndpoint == nil
            && serverSelection == nil
        let commandPath = (defaults.string(forKey: commandPathKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SubrouterConfiguration(
            isEnabled: isEnabled
                && !endpointSettingIsInvalid
                && !registryBlocksConfiguration,
            endpoint: endpoint ?? .standard,
            serverName: serverName,
            commandPath: commandPath.isEmpty ? nil : commandPath
        )
    }

    /// The outcome of reading `sr`'s server registry.
    ///
    /// `nil` inside ``selection(_:)`` means the local daemon is genuinely
    /// selected (no registry yet, or the default entry targets the local
    /// daemon). ``unreadable`` is kept distinct: an existing registry that
    /// cannot be read or decoded must never be mistaken for an intentional
    /// local selection, or configuration would fall back to loopback and a
    /// `subrouter.switch` could pass the local-switch guard against the
    /// wrong daemon.
    enum ServerRegistryState: Sendable {
        case selection(SubrouterServerSelection.Server?)
        case unreadable
    }

    /// Reads the `sr` server registry's default entry. Synchronous disk
    /// I/O: call off the main actor and cache the result (see
    /// ``SubrouterAppRuntime``).
    nonisolated static func loadServerRegistryState() -> ServerRegistryState {
        let registry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".subrouter/codex/servers.json")
        guard FileManager.default.fileExists(atPath: registry.path) else {
            return .selection(nil)
        }
        guard let data = try? Data(contentsOf: registry),
              let parsed = SubrouterServerSelection(serversJSON: data) else {
            return .unreadable
        }
        return .selection(parsed.defaultServer)
    }
}
