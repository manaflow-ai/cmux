import Foundation

/// Stable on-disk locations + port for the inline serve-web server. Keeping these
/// fixed across launches is what lets VS Code Web's keyring/secret-storage survive
/// reloads, folder changes, and app relaunches (issue #6595).
struct VSCodeServeWebRuntimeLocation: Equatable {
    /// `--server-data-dir`: where serve-web keeps its server-side state.
    let serverDataDirectoryURL: URL
    /// `--user-data-dir` for the cached code-server fallback (the wrapper derives
    /// this from `--server-data-dir` and rejects the flag).
    let userDataDirectoryURL: URL
    /// `VSCODE_CLI_DATA_DIR` for the wrapper's CLI keyring metadata.
    let cliDataDirectoryURL: URL
    /// `--connection-token-file`: a persisted token so the server URL is stable.
    let connectionTokenFileURL: URL
    /// Stable serve-web port (or `0` for the ephemeral fallback attempt).
    let port: Int
}
