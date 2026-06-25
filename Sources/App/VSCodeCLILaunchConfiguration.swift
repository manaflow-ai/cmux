import Foundation

nonisolated struct VSCodeCLILaunchConfiguration {
    let executableURL: URL
    let argumentsPrefix: [String]
    let environment: [String: String]
    let usesCodeTunnelWrapper: Bool
    let supportsUserDataDirectoryArgument: Bool

    func processArguments(for launchOptions: VSCodeServeWebLaunchOptions) -> [String] {
        argumentsPrefix + launchOptions.arguments(
            includeUserDataDirectory: supportsUserDataDirectoryArgument
        )
    }

    func processEnvironment(for launchOptions: VSCodeServeWebLaunchOptions) -> [String: String] {
        var processEnvironment = environment
        if usesCodeTunnelWrapper {
            processEnvironment["VSCODE_CLI_USE_FILE_KEYCHAIN"] = "1"
            processEnvironment["VSCODE_CLI_USE_FILE_KEYRING"] = "1"
            processEnvironment["VSCODE_CLI_DATA_DIR"] = launchOptions.serverDataDirectoryURL
                .appendingPathComponent("cli-data", isDirectory: true)
                .path
        }
        return processEnvironment
    }
}
