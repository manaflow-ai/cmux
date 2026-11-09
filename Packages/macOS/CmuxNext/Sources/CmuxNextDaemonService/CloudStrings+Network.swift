import Foundation

/// What the network, domain, publication and API key actions say. Keys
/// live in Resources/Cloud.xcstrings with every app locale.
public extension CloudStrings {
    /// A tunnel, network or firewall action: classic cmux.com served those, and cmux-platform
    /// serves none of them yet, so the action is unavailable instead of waiting on a route.
    static var notOnThisCloudYet: String {
        String(localized: "cloud.network.notOnThisCloudYet",
               defaultValue: "Tunnels, networks and firewall rules aren't available on this Cloud yet.",
               table: "Cloud", bundle: .module)
    }

    static var domainsTitle: String {
        String(localized: "cloud.result.domainsTitle", defaultValue: "Cloud Domains", table: "Cloud", bundle: .module)
    }

    static var publicationsTitle: String {
        String(localized: "cloud.result.publicationsTitle", defaultValue: "Cloud Publications", table: "Cloud", bundle: .module)
    }

    static var apiTitle: String {
        String(localized: "cloud.result.apiTitle", defaultValue: "Cloud API Ready", table: "Cloud", bundle: .module)
    }

    static var apiKeysTitle: String {
        String(localized: "cloud.result.apiKeysTitle", defaultValue: "Cloud API Keys", table: "Cloud", bundle: .module)
    }

    /// Provision API's answer: the URL, the key (answered this once) and how a client sends it.
    static func provisionedAPI(url: String, key: String, cookie: String) -> String {
        String(format: String(localized: "cloud.api.provisioned",
                              defaultValue: "URL: %1$@\nAPI key (shown once, keep it secret): %2$@\nClients send the key as a cookie, for example: curl -H 'Cookie: %3$@' %1$@",
                              table: "Cloud", bundle: .module), url, key, cookie)
    }

    /// `cloud api-key-list` / `api-key-revoke` without a publication.
    static var publicationRequired: String {
        String(localized: "cloud.api.publicationRequired",
               defaultValue: "Pass the publication id or hostname with --path <publication>; `cmux cloud publication-list` lists them.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud api-key-revoke` without a key id.
    static var apiKeyRequired: String {
        String(localized: "cloud.api.keyRequired",
               defaultValue: "Pass the API key id with --key <key-id>; `cmux cloud api-key-list --path <publication>` lists ids.",
               table: "Cloud", bundle: .module)
    }

    static func apiKeyRevoked(_ id: String) -> String {
        String(format: String(localized: "cloud.api.keyRevoked", defaultValue: "Revoked API key %@. Requests with it are refused from now on.",
                              table: "Cloud", bundle: .module), id)
    }
}
