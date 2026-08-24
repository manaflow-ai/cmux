public import Foundation
public import CmuxFoundation
import os

/// The production ``SubrouterAccountSwitching``: runs the `sr` CLI through
/// the shared ``CmuxFoundation/CommandRunning`` seam.
///
/// Binary resolution order: the explicit `commandPath` setting when present;
/// otherwise `sr` then `subrouter` resolved against `PATH` plus the standard
/// install locations (`~/bin`, Homebrew paths). Only the account id crosses
/// the process boundary — never any credential material.
public struct SubrouterCommandSwitcher: SubrouterAccountSwitching {
    private nonisolated static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "SubrouterCommandSwitcher"
    )

    /// Deadline for one `sr` invocation (it may refresh a token upstream).
    public static let commandTimeout: TimeInterval = 30

    private let commandRunner: any CommandRunning
    private let workingDirectory: String

    /// Creates the production switcher.
    /// - Parameters:
    ///   - commandRunner: The subprocess seam; defaults to a runner whose
    ///     fallback search path includes `~/bin` (the subrouter installer's
    ///     non-root default) after the standard Homebrew locations.
    ///   - workingDirectory: The working directory for `sr`; defaults to the
    ///     user's home directory.
    public init(
        commandRunner: (any CommandRunning)? = nil,
        workingDirectory: String = NSHomeDirectory()
    ) {
        self.commandRunner = commandRunner ?? CommandRunner(
            fallbackSearchDirectories: CommandRunner.defaultFallbackSearchDirectories
                + [
                    (NSHomeDirectory() as NSString).appendingPathComponent("bin"),
                    // Where the cmux CLI extracts the app-bundled subrouter
                    // binary (CLI/CMUXCLI+BundledSubrouter.swift), so
                    // switching works without a separately installed sr.
                    (NSHomeDirectory() as NSString)
                        .appendingPathComponent("Library/Application Support/cmux/bin"),
                ]
        )
        self.workingDirectory = workingDirectory
    }

    public func switchAccount(
        provider: SubrouterProvider,
        accountID: String,
        commandPath: String?
    ) async throws {
        let arguments = try Self.switchArguments(provider: provider, accountID: accountID)
        let executables: [String]
        let trimmedCommandPath = commandPath?.trimmingCharacters(in: .whitespaces) ?? ""
        if !trimmedCommandPath.isEmpty {
            // Settings accepts values like `~/bin/subrouter`; neither
            // CommandRunner nor /usr/bin/env expands a tilde, so resolve it
            // here or the configured path silently never launches.
            executables = [(trimmedCommandPath as NSString).expandingTildeInPath]
        } else {
            executables = ["sr", "subrouter"]
        }

        var sawLaunchFailure = false
        for executable in executables {
            let result = await commandRunner.run(
                directory: workingDirectory,
                executable: executable,
                arguments: arguments,
                timeout: Self.commandTimeout
            )
            if result.executionError != nil {
                sawLaunchFailure = true
                continue
            }
            if result.timedOut {
                throw SubrouterSwitchError.commandTimedOut
            }
            if result.exitStatus == 0 {
                return
            }
            Self.logFailure(result)
            throw SubrouterSwitchError.commandFailed
        }
        if sawLaunchFailure {
            throw SubrouterSwitchError.commandNotFound
        }
        throw SubrouterSwitchError.commandNotFound
    }

    /// The `sr` argument vector for a switch, or a thrown
    /// ``SubrouterSwitchError/switchUnsupported(provider:)`` when the
    /// provider has no switch verb.
    static func switchArguments(
        provider: SubrouterProvider,
        accountID: String
    ) throws -> [String] {
        switch provider {
        case .codex:
            return ["switch", accountID]
        case .claude:
            return ["claude", "switch", accountID]
        default:
            throw SubrouterSwitchError.switchUnsupported(provider: provider)
        }
    }

    private static func logFailure(_ result: CommandResult) {
        let stderr = result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stdout = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = result.exitStatus.map(String.init) ?? "unknown"
        Self.logger.error(
            "sr command failed: status=\(status, privacy: .public) stderr=\(stderr, privacy: .private(mask: .hash)) stdout=\(stdout, privacy: .private(mask: .hash))"
        )
    }
}
