import Foundation

/// Settings under the dotted-id prefix `inlineVSCode.*`.
///
/// These control how the built-in "Open Current Directory in VS Code (Inline)"
/// command launches VS Code's `serve-web`. All four keys are JSON-backed so they
/// live in `~/.config/cmux/cmux.json` and can be edited either through the
/// Settings UI or by hand. They are read by the macOS app's serve-web launcher
/// at (re)start time; changing a value takes effect the next time inline VS Code
/// starts (use "Restart Inline VS Code" to apply immediately).
public struct InlineVSCodeCatalogSection: SettingCatalogSection {
    /// Whether `serve-web` keeps its state (sign-in, Settings Sync, …) across
    /// launches. Default `true`. When `false` (and no ``serverDataDir`` is set),
    /// a throwaway data directory is used so nothing persists between launches.
    public let persistServeWebState = JSONKey<Bool>(
        id: "inlineVSCode.persistServeWebState",
        defaultValue: true
    )

    /// Local port `serve-web` binds. Default `0`, which selects a random free
    /// port. Set a value in `1...65535` to pin the port.
    public let port = JSONKey<Int>(
        id: "inlineVSCode.port",
        defaultValue: 0
    )

    /// The `serve-web` server data directory (`--server-data-dir`). Empty (the
    /// default) uses the upstream VS Code default location. A leading `~`
    /// expands to the home directory.
    public let serverDataDir = JSONKey<String>(
        id: "inlineVSCode.serverDataDir",
        defaultValue: ""
    )

    /// Advanced upstream VS Code `serve-web` flags appended after the
    /// cmux-managed arguments. cmux-owned flags (host, port, connection token,
    /// server data dir) are stripped so the loopback + connection-token
    /// invariants hold. Empty by default.
    public let extraArgs = JSONKey<[String]>(
        id: "inlineVSCode.extraArgs",
        defaultValue: []
    )

    /// Creates the section with its fixed set of `inlineVSCode.*` keys.
    public init() {}
}
