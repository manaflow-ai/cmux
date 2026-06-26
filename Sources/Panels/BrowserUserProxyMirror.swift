import CmuxSettings
import CmuxSettingsUI
import Foundation
import Network

extension Notification.Name {
    /// Posted on the main thread when the user-configured browser proxy
    /// (`cmux.json` `browser.proxy`) may have changed — currently after a
    /// `cmux reload-config`. Local browser panes observe it and re-apply their
    /// proxy configuration, mirroring how `.browserSystemProxySettingsDidChange`
    /// refreshes the system-proxy mirror.
    static let browserUserProxyConfigurationDidChange =
        Notification.Name("cmux.browser.userProxyConfigurationDidChange")
}

/// Builds the `WKWebsiteDataStore.proxyConfigurations` a local browser pane
/// should use for a *user-configured* proxy — `cmux.json`'s `browser.proxy`
/// object or the `CMUX_BROWSER_PROXY` environment override
/// (https://github.com/manaflow-ai/cmux/issues/6639).
///
/// This is the explicit, opt-in companion to ``BrowserSystemProxyMirror``: that
/// type mirrors the *macOS system* proxy with loopback excluded; this one
/// applies a proxy the user asked cmux to use regardless of the system setting.
/// When a user proxy is enabled it takes precedence over the system mirror;
/// when it is not, the pane falls back to the system mirror unchanged. Remote
/// workspace panes are never affected — they keep routing through their
/// workspace tunnel.
///
/// Like the system mirror, failover stays disabled (the platform default) so
/// traffic meant for the proxy never silently falls back to a direct
/// connection, and loopback/link-local hosts always connect directly via the
/// merged exclusion list.
enum BrowserUserProxyMirror {
    /// The effective user proxy configuration: `cmux.json`'s `browser.proxy`
    /// with the `CMUX_BROWSER_PROXY` override applied. Reads the settings
    /// store's synchronous snapshot, so it is safe to call on the main actor
    /// before any suspension point. Returns ``BrowserProxyConfiguration/disabled``
    /// when no settings runtime is available yet.
    @MainActor
    static func currentConfiguration() -> BrowserProxyConfiguration {
        let fileConfiguration: BrowserProxyConfiguration
        if let runtime = AppDelegate.shared?.settingsRuntime {
            fileConfiguration = runtime.jsonStore.snapshotValue(for: runtime.catalog.browser.proxy)
        } else {
            fileConfiguration = .disabled
        }
        return BrowserProxyConfiguration.resolved(fileConfiguration: fileConfiguration)
    }

    /// The configurations a local-workspace data store should use for the
    /// user-configured proxy, or `nil` when no user proxy is enabled — the
    /// caller then falls back to the system-proxy mirror.
    @MainActor
    static func currentProxyConfigurations() -> [ProxyConfiguration]? {
        proxyConfigurations(for: currentConfiguration())
    }

    /// Converts a resolved configuration into Network.framework proxy
    /// configurations, or `nil` when the configuration is not a usable proxy.
    ///
    /// Pure given its input (no settings/environment reads) so it is unit
    /// testable. Authenticated proxies carry their credentials; the excluded
    /// domains merge the always-on loopback/link-local defaults with the user's
    /// normalized bypass list.
    static func proxyConfigurations(
        for configuration: BrowserProxyConfiguration
    ) -> [ProxyConfiguration]? {
        guard configuration.isEnabled,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
            return nil
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.trimmedHost),
            port: nwPort
        )

        var proxyConfiguration: ProxyConfiguration
        switch configuration.type {
        case .socks5:
            proxyConfiguration = ProxyConfiguration(socksv5Proxy: endpoint)
        case .httpConnect:
            proxyConfiguration = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .off:
            return nil
        }

        if configuration.hasCredentials {
            proxyConfiguration.applyCredential(
                username: configuration.username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: configuration.password
            )
        }
        proxyConfiguration.excludedDomains = mergedExcludedDomains(
            userBypass: configuration.normalizedBypassDomains
        )
        return [proxyConfiguration]
    }

    /// Merges the always-on loopback/link-local exclusions with the user's
    /// normalized bypass entries, keeping the implicit defaults first and
    /// dropping duplicates. Reuses ``BrowserSystemProxyMirror/implicitExclusions``
    /// so both proxy sources guarantee the same loopback bypass
    /// (https://github.com/manaflow-ai/cmux/issues/5888).
    static func mergedExcludedDomains(userBypass: [String]) -> [String] {
        var seen = Set(BrowserSystemProxyMirror.implicitExclusions)
        var merged = BrowserSystemProxyMirror.implicitExclusions
        for entry in userBypass where seen.insert(entry).inserted {
            merged.append(entry)
        }
        return merged
    }
}
