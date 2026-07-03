import Foundation

/// Shapes the final process arguments + environment per launcher kind. The wrapper
/// and the cached code-server differ in supported flags and in how they manage the
/// secret keyring, so the two paths are handled explicitly here.
enum VSCodeServeWebLaunchOptionsBuilder {
    static func launchOptions(
        configuration: VSCodeCLILaunchConfiguration,
        location: VSCodeServeWebRuntimeLocation,
        port: Int
    ) -> VSCodeServeWebLaunchOptions {
        var arguments = configuration.argumentsPrefix
        arguments += [
            "--accept-server-license-terms",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--connection-token-file", location.connectionTokenFileURL.path,
            "--server-data-dir", location.serverDataDirectoryURL.path,
        ]
        var environment = configuration.environment

        switch configuration.launcherKind {
        case .codeTunnelWrapper:
            // `code-tunnel serve-web` does not accept --user-data-dir; it derives
            // user data from --server-data-dir. Enable the CLI file keyring so VS
            // Code Web auth/Settings Sync persist instead of using in-memory
            // secret storage, and pin the CLI data dir for keyring stability.
            environment["VSCODE_CLI_USE_FILE_KEYRING"] = "1"
            let cliDataKey = VSCodeServeWebRuntimeLocator.cliDataDirectoryEnvironmentKey
            let cliDataDirIsUnset = environment[cliDataKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true
            if cliDataDirIsUnset {
                environment[cliDataKey] = location.cliDataDirectoryURL.path
            }
        case .cachedCodeServer:
            // The cached server binary accepts --user-data-dir directly.
            arguments += ["--user-data-dir", location.userDataDirectoryURL.path]
        }

        return VSCodeServeWebLaunchOptions(
            executableURL: configuration.executableURL,
            arguments: arguments,
            environment: environment
        )
    }
}
