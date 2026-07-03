/// Which binary backs the inline serve-web launch. The two differ in how VS Code
/// Web persists auth/Settings Sync state, so downstream launch options are shaped
/// per kind (see ``VSCodeServeWebLaunchOptionsBuilder``).
enum VSCodeServeWebLauncherKind: Equatable {
    /// `code-tunnel serve-web`: the wrapper that wires up the CLI
    /// secret-storage/keyring path VS Code Web auth + Settings Sync rely on.
    case codeTunnelWrapper
    /// Cached `~/.vscode/cli/serve-web/<id>/bin/code-server`, used only as a
    /// fallback for installs where the wrapper is unavailable. Bypasses the
    /// wrapper-managed keyring setup.
    case cachedCodeServer
}
