import CmuxFoundation
import Foundation

/// Proves an SSH route authenticates without a prompt before the headless carrier starts.
///
/// The carrier cannot answer a password, keyboard-interactive or host-key prompt,
/// and it retries OpenSSH's own failures until its startup deadline. A batch-mode
/// `ssh … true` returns OpenSSH's diagnostic in seconds instead. With connection
/// sharing configured it also opens the master the carrier then multiplexes over.
public struct SSHTuiPreflight: Sendable {
    public init(connection: SSHTuiConnection, commands: any CommandRunning = CommandRunner(), timeout: TimeInterval = 30) {
        self.connection = connection
        self.commands = commands
        self.timeout = timeout
    }

    public let connection: SSHTuiConnection
    private let commands: any CommandRunning
    private let timeout: TimeInterval

    public func run() async throws {
        var arguments = connection.preflightArguments
        var executable = arguments.removeFirst()
        // The child inherits the app environment, so the caller's agent is
        // passed the same way the carrier receives it.
        if let agent = connection.configuration.agentSocketPath {
            arguments = ["SSH_AUTH_SOCK=" + agent, executable] + arguments
            executable = "/usr/bin/env"
        }
        let result = await commands.run(
            directory: NSHomeDirectory(), executable: executable, arguments: arguments, timeout: timeout
        )
        if let failure = result.executionError {
            try Task.checkCancellation()
            throw SSHTuiPreflightError.launchFailed(failure)
        }
        if result.timedOut { throw SSHTuiPreflightError.timedOut }
        // 255 is OpenSSH's own failure. Any other status came from the remote
        // `true`, so the route works and the carrier owns what follows.
        if result.exitStatus == 255 { throw SSHTuiPreflightError.sshFailed(result.stderr ?? "") }
    }
}

public enum SSHTuiPreflightError: LocalizedError, Equatable, Sendable {
    /// OpenSSH failed its own connection; carries its standard error.
    case sshFailed(String)
    case timedOut
    case launchFailed(String)

    /// OpenSSH's whole standard error, or the empty string. Classify this, not
    /// `diagnostic`, so chatty ProxyCommand output cannot push a marker out.
    public var standardError: String {
        guard case .sshFailed(let output) = self else { return "" }
        return output
    }

    /// OpenSSH's diagnostic without blank lines, or the empty string.
    public var diagnostic: String {
        standardError.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(8)
            .joined(separator: "\n")
    }

    /// Whether the route stopped before OpenSSH could authenticate. A
    /// ProxyCommand waiting on a login it cannot show stalls here, and an
    /// interactive run lets that prompt reach the user.
    public var stalledBeforeAuthentication: Bool {
        switch self {
        case .timedOut: return true
        case .sshFailed: return standardError.localizedCaseInsensitiveContains("timed out during banner exchange")
        case .launchFailed: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .sshFailed:
            let diagnostic = diagnostic
            return diagnostic.isEmpty
                ? String(localized: "cloud.link.sshPreflight.failed", defaultValue: "SSH could not connect to the host.")
                : diagnostic
        case .timedOut:
            return String(localized: "cloud.link.sshPreflight.timedOut", defaultValue: "SSH did not finish connecting in time.")
        case .launchFailed(let detail):
            return String(
                format: String(localized: "cloud.link.sshPreflight.launchFailed", defaultValue: "SSH could not be started: %@"),
                detail
            )
        }
    }
}
