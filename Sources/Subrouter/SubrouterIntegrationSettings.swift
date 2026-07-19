import Foundation
import CmuxSubrouter

/// Reads the subrouter integration settings from `UserDefaults` (the keys
/// declared in `CmuxSettings`' `SubrouterCatalogSection` and the sidebar
/// catalog) and assembles the store's ``SubrouterConfiguration``.
enum SubrouterIntegrationSettings {
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
    /// Reads the flag via `assumeIsolated`: every caller (mode availability,
    /// panel/footer views, the app runtime) is main-actor, and the socket
    /// lane reads the store's captured configuration instead of calling this.
    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        let flagEnabled = MainActor.assumeIsolated {
            CmuxFeatureFlags.shared.isSubrouterUIEnabled
        }
        return flagEnabled && userOptIn(defaults: defaults)
    }

    /// The raw `subrouter.enabled` setting, without the feature flag.
    nonisolated static func userOptIn(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }

    /// Whether the left-sidebar footer switcher should render: the master
    /// gate plus its own toggle.
    nonisolated static func showsAccountSwitcher(defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(defaults: defaults) else { return false }
        guard defaults.object(forKey: showAccountSwitcherKey) != nil else {
            return defaultShowAccountSwitcher
        }
        return defaults.bool(forKey: showAccountSwitcherKey)
    }

    /// The store configuration derived from current defaults.
    ///
    /// Endpoint resolution mirrors the `sr` CLI so cmux always watches the
    /// daemon that is actually routing this machine's agents: an explicit
    /// `subrouter.endpoint` setting wins; otherwise the `sr server` default
    /// from `~/.subrouter/codex/servers.json`; otherwise the local loopback
    /// daemon. An empty command path means resolve `sr` from `PATH`.
    nonisolated static func currentConfiguration(defaults: UserDefaults = .standard) -> SubrouterConfiguration {
        let explicitEndpoint = SubrouterEndpoint(
            configurationString: defaults.string(forKey: endpointKey) ?? ""
        )
        var serverName: String?
        var endpoint = explicitEndpoint
        if endpoint == nil, let server = defaultServerSelection() {
            endpoint = server.endpoint
            serverName = server.name
        }
        let commandPath = (defaults.string(forKey: commandPathKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SubrouterConfiguration(
            isEnabled: isEnabled(defaults: defaults),
            endpoint: endpoint ?? .standard,
            serverName: serverName,
            commandPath: commandPath.isEmpty ? nil : commandPath
        )
    }

    /// Reads the `sr` server registry's default entry, or `nil` when the
    /// registry is missing, unreadable, or targets the local daemon.
    private nonisolated static func defaultServerSelection() -> SubrouterServerSelection.Server? {
        let registry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".subrouter/codex/servers.json")
        guard let data = try? Data(contentsOf: registry) else { return nil }
        return SubrouterServerSelection(serversJSON: data)?.defaultServer
    }
}
