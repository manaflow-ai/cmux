import Foundation

/// Environment keys supplied to a supervised process-backed plugin.
///
/// Values are deliberately plain strings so a plugin can start with only its
/// standard-library process and JSON support. The token is short-lived and is
/// invalidated when the plugin is disabled or its manifest changes.
public struct CmuxPluginEnvironment: Sendable {
    /// The plugin identifier declared in `manifest.json`.
    public static let pluginIDKey = "CMUX_PLUGIN_ID"
    /// The in-memory token required by the plugin-tagged event stream.
    public static let pluginTokenKey = "CMUX_PLUGIN_TOKEN"
    /// The active cmux control-socket path.
    public static let pluginSocketPathKey = "CMUX_PLUGIN_SOCKET_PATH"
    /// Absolute path to the validated manifest file.
    public static let manifestPathKey = "CMUX_PLUGIN_MANIFEST_PATH"
    /// The negotiated plugin API version (`major.minor`).
    public static let apiVersionKey = "CMUX_PLUGIN_API_VERSION"
    /// Conventional socket variable also understood by bundled cmux clients.
    public static let socketPathKey = "CMUX_SOCKET_PATH"

    private init() {}
}
