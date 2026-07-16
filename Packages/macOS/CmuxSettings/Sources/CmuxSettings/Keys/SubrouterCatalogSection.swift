import Foundation

/// Settings under the dotted-id prefix `subrouter.*` — the local subrouter
/// daemon integration (AI-agent account switching and usage analytics).
public struct SubrouterCatalogSection: SettingCatalogSection {
    /// The master gate. Defaults to `false` so cmux never issues subrouter
    /// daemon traffic or `sr` subprocess calls without an explicit opt-in;
    /// enabling reveals the Agents right-sidebar mode and the footer
    /// account switcher.
    public let enabled = DefaultsKey<Bool>(
        id: "subrouter.enabled",
        defaultValue: false,
        userDefaultsKey: "subrouterEnabled"
    )

    /// The daemon address. Empty means the standard loopback bind,
    /// `http://127.0.0.1:31415`. Accepts `host:port` or a full `http(s)`
    /// URL.
    public let endpoint = DefaultsKey<String>(
        id: "subrouter.endpoint",
        defaultValue: "",
        userDefaultsKey: "subrouterEndpoint"
    )

    /// An explicit path to the `sr`/`subrouter` CLI used for account
    /// switches. Empty means resolve from `PATH` and the standard install
    /// locations (`~/bin`, Homebrew).
    public let commandPath = DefaultsKey<String>(
        id: "subrouter.commandPath",
        defaultValue: "",
        userDefaultsKey: "subrouterCommandPath"
    )

    public init() {}
}
