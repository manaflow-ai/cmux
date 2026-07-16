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

    static let defaultEnabled = false
    static let defaultShowAccountSwitcher = true

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
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

    /// The store configuration derived from current defaults. An empty or
    /// unparsable endpoint falls back to the daemon's standard loopback
    /// address; an empty command path means resolve `sr` from `PATH`.
    nonisolated static func currentConfiguration(defaults: UserDefaults = .standard) -> SubrouterConfiguration {
        let endpoint = SubrouterEndpoint(
            configurationString: defaults.string(forKey: endpointKey) ?? ""
        ) ?? .standard
        let commandPath = (defaults.string(forKey: commandPathKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SubrouterConfiguration(
            isEnabled: isEnabled(defaults: defaults),
            endpoint: endpoint,
            commandPath: commandPath.isEmpty ? nil : commandPath
        )
    }
}
