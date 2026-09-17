import Foundation

/// Settings for the in-app updater, the `updates.*` keys.
public struct UpdatesCatalogSection: SettingCatalogSection {
    /// Which update feed the install polls: `stable` (default) or `rc`.
    ///
    /// JSON-backed so it can be flipped by editing `~/.config/cmux/cmux.json`
    /// and takes effect on the next update check without a relaunch:
    ///
    /// ```json
    /// { "updates": { "channel": "rc" } }
    /// ```
    public let channel = JSONKey<UpdateChannel>(
        id: "updates.channel",
        defaultValue: .stable
    )

    public init() {}
}
