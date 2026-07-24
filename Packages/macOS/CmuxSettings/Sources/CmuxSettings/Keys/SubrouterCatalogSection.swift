import Foundation

/// Settings under the dotted-id prefix `subrouter.*` — the local subrouter
/// daemon integration (AI-agent account switching and usage analytics).
public struct SubrouterCatalogSection: SettingCatalogSection {
    /// The user's opt-out inside the subrouter feature flag
    /// (`CmuxFeatureFlags.isSubrouterUIEnabled`): rollout is controlled by
    /// the flag, and this setting (default on) lets a user turn the
    /// integration off. While either is off, cmux
    /// issues no subrouter daemon traffic and no `sr` subprocess calls, and
    /// the Agents right-sidebar mode and footer account switcher are hidden.
    public let enabled = DefaultsKey<Bool>(
        id: "subrouter.enabled",
        defaultValue: true,
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
