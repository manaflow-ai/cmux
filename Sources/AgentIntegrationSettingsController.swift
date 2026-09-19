import CmuxFoundation
import CmuxSettingsUI
import Foundation
import OSLog

private let agentIntegrationSettingsLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "AgentIntegrationSettings"
)

/// Host-side adapter for the hook installer owned by the bundled cmux CLI.
///
/// Settings never reconstructs agent config files. Reads and mutations both go
/// through the same CLI implementation users can invoke from a terminal.
struct AgentIntegrationSettingsController: Sendable {
    private struct StatusPayload: Decodable {
        let integration: String
        let state: AgentIntegrationInstallState
    }

    private let commands: any CommandRunning
    private let executablePath: String
    private let workingDirectory: String

    init(
        commands: any CommandRunning = CommandRunner(),
        executablePath: String? = nil,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.commands = commands
        workingDirectory = environment["HOME"] ?? NSHomeDirectory()

        if let executablePath, !executablePath.isEmpty {
            self.executablePath = executablePath
        } else if let bundledPath = environment["CMUX_BUNDLED_CLI_PATH"], !bundledPath.isEmpty {
            self.executablePath = bundledPath
        } else if let resourceURL = bundle.resourceURL {
            self.executablePath = resourceURL.appendingPathComponent("bin/cmux", isDirectory: false).path
        } else {
            self.executablePath = bundle.bundleURL
                .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
                .path
        }
    }

    func installState(
        _ integration: AgentIntegrationInstallTarget
    ) async -> AgentIntegrationInstallState {
        let result = await run([
            "hooks",
            integration.rawValue,
            "install",
            "--status-json",
        ])
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0,
              let stdout = result.stdout,
              let data = stdout.data(using: .utf8),
              let payload = try? JSONDecoder().decode(StatusPayload.self, from: data),
              payload.integration == integration.rawValue else {
            return .unavailable
        }
        return payload.state
    }

    func perform(
        _ action: AgentIntegrationInstallAction,
        for integration: AgentIntegrationInstallTarget
    ) async -> AgentIntegrationActionResult {
        let arguments: [String]
        switch action {
        case .install, .repair:
            arguments = ["hooks", integration.rawValue, "install", "--yes"]
        case .remove:
            arguments = ["hooks", integration.rawValue, "uninstall"]
        case .openInstructions:
            return AgentIntegrationActionResult(
                succeeded: false,
                message: "Open-instructions is handled by the app host."
            )
        }

        let result = await run(arguments)
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else {
            let diagnostics = result.executionError
                ?? result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let diagnostics, !diagnostics.isEmpty {
                agentIntegrationSettingsLogger.error(
                    "Agent hook installer failed for \(integration.rawValue, privacy: .public): " +
                    "\(diagnostics, privacy: .private)"
                )
            }
            return AgentIntegrationActionResult(
                succeeded: false,
                message: String(
                    localized: "settings.automation.integration.install.failed",
                    defaultValue: "The hook installer could not complete the requested action."
                )
            )
        }
        return .success
    }

    private func run(_ arguments: [String]) async -> CommandResult {
        await commands.run(
            directory: workingDirectory,
            executable: executablePath,
            arguments: arguments,
            timeout: 8
        )
    }
}
