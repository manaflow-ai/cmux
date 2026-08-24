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
            environment: Self.scrubbedEnvironment(),
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
        commandPath: String?,
        target: SubrouterAccountTarget = .local
    ) async throws {
        // Extraction is lazy and off the main actor: settings/runtime startup
        // must not synchronously gunzip an app resource when the panel is only
        // being constructed. Cancellation of the awaiting switch abandons the
        // result; the next switch retries the fingerprinted extraction.
        _ = await Task.detached(priority: .utility) {
            Self.ensureBundledSubrouter()
        }.value
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
        let environmentOverrides = Self.serverEnvironment(target: target)
        for executable in executables {
            let result: CommandResult
            if let environmentRunner = commandRunner as? any EnvironmentCommandRunning {
                result = await environmentRunner.run(
                    directory: workingDirectory,
                    executable: executable,
                    arguments: arguments,
                    timeout: Self.commandTimeout,
                    environmentOverrides: environmentOverrides
                )
            } else {
                result = await commandRunner.run(
                    directory: workingDirectory,
                    executable: executable,
                    arguments: arguments,
                    timeout: Self.commandTimeout
                )
            }
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

    private static func serverEnvironment(target: SubrouterAccountTarget) -> [String: String] {
        let value: String
        switch target {
        case .local:
            value = "local"
        case .server(let name):
            value = name
        }
        // Set both names so a shell-provided provider-neutral value cannot
        // override an explicit target selected by cmux.
        return [
            "SUBROUTER_SERVER": value,
            "SUBROUTER_CODEX_SERVER": value,
        ]
    }

    private static func scrubbedEnvironment() -> [String: String] {
        let allowedPrefixes = [
            "PATH", "HOME", "USER", "LOGNAME", "SHELL", "PWD", "OLDPWD",
            "TMPDIR", "TERM", "LANG", "LC_", "SUBROUTER_", "CODEX_",
            "CLAUDE_", "ANTHROPIC_", "OPENAI_", "XDG_"
        ]
        return ProcessInfo.processInfo.environment.filter { key, _ in
            allowedPrefixes.contains { prefix in
                prefix.hasSuffix("_") ? key.hasPrefix(prefix) : key == prefix
            }
        }
    }

    /// Extracts the app-bundled binary into the same Application Support
    /// directory searched by the default ``CommandRunner``. User-installed
    /// binaries still win; this is only a fallback for a pristine install.
    private static func ensureBundledSubrouter() -> String? {
        guard let archiveURL = Bundle.main.url(
            forResource: "subrouter",
            withExtension: "gz",
            subdirectory: "bin"
        ) else { return nil }
        let fileManager = FileManager.default
        let installDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("cmux/bin", isDirectory: true)
        let binaryURL = installDirectory.appendingPathComponent("subrouter")
        let personaURL = installDirectory.appendingPathComponent("sr")
        let fingerprintURL = installDirectory.appendingPathComponent(".subrouter.fingerprint")
        guard let attributes = try? fileManager.attributesOfItem(atPath: archiveURL.path),
              let size = attributes[.size] as? Int64,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        let fingerprint = "\(size)-\(Int(modified.timeIntervalSince1970))"
        let current = (try? String(contentsOf: fingerprintURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if current != fingerprint || !fileManager.isExecutableFile(atPath: binaryURL.path) {
            do {
                try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
                let stagingURL = installDirectory.appendingPathComponent(
                    ".subrouter.extracting.\(ProcessInfo.processInfo.processIdentifier)"
                )
                try? fileManager.removeItem(at: stagingURL)
                defer { try? fileManager.removeItem(at: stagingURL) }
                guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
                    return nil
                }
                let output = try FileHandle(forWritingTo: stagingURL)
                defer { output.closeFile() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
                process.arguments = ["-c", archiveURL.path]
                process.standardOutput = output
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                output.closeFile()
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingURL.path)
                try? fileManager.removeItem(at: binaryURL)
                try fileManager.moveItem(at: stagingURL, to: binaryURL)
                try fingerprint.write(to: fingerprintURL, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: personaURL.path)) != "subrouter" {
            try? fileManager.removeItem(at: personaURL)
            try? fileManager.createSymbolicLink(
                atPath: personaURL.path,
                withDestinationPath: "subrouter"
            )
        }
        return fileManager.isExecutableFile(atPath: personaURL.path) ? personaURL.path : nil
    }
}
