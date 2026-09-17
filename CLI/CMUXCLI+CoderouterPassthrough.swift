import Darwin
import Foundation

// `cmux cr ...`, and every `cmux coderouter ...` verb cmux does not own
// (CMUXCLI+Coderouter.swift), run the separately distributed CodeRouter CLI.
// This file owns that passthrough end to end: locating the executable,
// bootstrapping it on a machine that has none, and replacing this process
// with it. The cmux socket is never opened on this path.
extension CMUXCLI {
    /// The installer documented at https://cmux.com/coderouter. Every message
    /// quotes this exact command, and the interactive bootstrap runs it: cmux
    /// fetches the script and hands it to `sh` as two separate steps, so a
    /// failed or truncated download never reaches the shell. The script itself
    /// verifies the binary's checksum against the release manifest.
    static let coderouterInstallerURL = "https://cmux.com/coderouter/install.sh"
    static let coderouterInstallCommand = "curl -fsSL \(coderouterInstallerURL) | sh"

    private static let coderouterExecutableNames = ["coderouter", "cr"]

    /// Where install.sh puts the binary: `$CODEROUTER_INSTALL/bin`, default
    /// `$HOME/.coderouter/bin`, computed exactly as the script does.
    static func coderouterInstallBinDirectory(environment: [String: String]) -> URL {
        let explicitRoot = environment["CODEROUTER_INSTALL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root: URL
        if !explicitRoot.isEmpty {
            root = URL(fileURLWithPath: explicitRoot, isDirectory: true)
        } else {
            let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            root = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".coderouter", isDirectory: true)
        }
        return root.appendingPathComponent("bin", isDirectory: true)
    }

    /// CodeRouter and its installer are independent executables. They never
    /// receive cmux's ambient terminal or control-plane context: CMUX_* and
    /// CMUXD_* may carry socket paths, capabilities, passwords, auth state, or
    /// internal paths. There is intentionally no auth handoff; a future one
    /// must be explicit and narrowly allowlisted.
    static func coderouterChildEnvironment(from environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !key.hasPrefix("CMUX_") && !key.hasPrefix("CMUXD_")
        }
    }

    func runCoderouterAlias(commandArgs: [String]) throws {
        let environment = ProcessInfo.processInfo.environment
        let executablePath: String
        if let installed = resolveCoderouterExecutable(environment: environment) {
            executablePath = installed
        } else {
            executablePath = try bootstrapCoderouter(environment: environment)
        }
        try execCoderouter(at: executablePath, commandArgs: commandArgs, environment: environment)
    }

    /// PATH first (`coderouter`, then `cr`), exactly as before, then the
    /// installer's bin directory, so an install whose shell-profile line has
    /// not reached this process still runs. No hit involves the network.
    func resolveCoderouterExecutable(environment: [String: String]) -> String? {
        for name in Self.coderouterExecutableNames {
            if let path = resolveExecutableInPath(name, searchPath: environment["PATH"]) {
                return path
            }
        }
        return resolveExecutableInPath(
            "coderouter",
            searchPath: Self.coderouterInstallBinDirectory(environment: environment).path
        )
    }

    // MARK: - Bootstrap

    /// Returns the path of a freshly installed CodeRouter CLI, or throws exit
    /// 127 carrying the exact install command whenever this process cannot or
    /// may not install: no terminal to ask on, a declined offer, a failed
    /// download, or a failed installer. The offer and the question go to
    /// stderr so stdout stays CodeRouter's; the answer comes from stdin, so
    /// both must be terminals.
    private func bootstrapCoderouter(environment: [String: String]) throws -> String {
        let installCommand = Self.coderouterInstallCommand
        guard isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else {
            throw Self.coderouterUnavailable(String(
                format: Self.localizedPassthroughString(
                    "cli.coderouter.bootstrap.notInstalled",
                    defaultValue: "CodeRouter CLI is not installed. Install it, then retry:\n  %@"
                ),
                installCommand
            ))
        }

        let binDirectory = Self.coderouterInstallBinDirectory(environment: environment)
        cliWriteStderr(String(
            format: Self.localizedPassthroughString(
                "cli.coderouter.bootstrap.offer",
                defaultValue: "CodeRouter CLI is not installed. cmux can install it now by running the official installer:\n  %1$@\nThis downloads the checksum-verified CodeRouter binary into %2$@ and adds that directory to your shell PATH."
            ),
            installCommand,
            binDirectory.path
        ) + "\n")
        cliWriteStderr(Self.localizedPassthroughString(
            "cli.coderouter.bootstrap.confirm",
            defaultValue: "Install CodeRouter now? [y/N] "
        ))
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard answer.hasPrefix("y") else {
            throw Self.coderouterUnavailable(String(
                format: Self.localizedPassthroughString(
                    "cli.coderouter.bootstrap.declined",
                    defaultValue: "CodeRouter was not installed. Install it later with:\n  %@"
                ),
                installCommand
            ))
        }

        cliWriteStderr(Self.localizedPassthroughString(
            "cli.coderouter.bootstrap.installing",
            defaultValue: "Installing CodeRouter..."
        ) + "\n")
        let childEnvironment = Self.coderouterChildEnvironment(from: environment)
        let installer = try fetchCoderouterInstaller(environment: environment, childEnvironment: childEnvironment)
        defer { installer.cleanUp() }
        let status = try Self.runCoderouterChild(
            executable: "/bin/sh",
            arguments: [installer.scriptURL.path],
            environment: childEnvironment
        )
        guard status == 0 else {
            throw Self.coderouterUnavailable(String(
                format: Self.localizedPassthroughString(
                    "cli.coderouter.bootstrap.installerFailed",
                    defaultValue: "The CodeRouter installer exited with status %1$d. Retry, or install it with:\n  %2$@"
                ),
                status,
                installCommand
            ))
        }
        guard let installed = resolveCoderouterExecutable(environment: environment) else {
            throw Self.coderouterUnavailable(String(
                format: Self.localizedPassthroughString(
                    "cli.coderouter.bootstrap.installedNotFound",
                    defaultValue: "The CodeRouter installer finished, but its command could not be found in %@. Check the installation and try again."
                ),
                binDirectory.path
            ))
        }
        return installed
    }

    private struct CoderouterInstallerScript {
        let scriptURL: URL
        /// Owned by cmux only when the script was downloaded here.
        let temporaryDirectory: URL?

        func cleanUp() {
            guard let temporaryDirectory else { return }
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    /// Downloads install.sh into a private temporary directory with the same
    /// transport rules the script applies to its own downloads (HTTPS only,
    /// TLS 1.2+). curl's stderr is inherited, so a network failure shows its
    /// own diagnosis before cmux's summary line.
    private func fetchCoderouterInstaller(
        environment: [String: String],
        childEnvironment: [String: String]
    ) throws -> CoderouterInstallerScript {
#if DEBUG
        // Tests run the bootstrap against a local stand-in for install.sh so
        // the offer, the install, the re-resolve, and the exec are exercised
        // without the network. Not compiled into release builds.
        if let override = environment["CMUX_CODEROUTER_INSTALLER_SCRIPT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return CoderouterInstallerScript(
                scriptURL: URL(fileURLWithPath: override, isDirectory: false),
                temporaryDirectory: nil
            )
        }
#endif
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let scriptURL = directory.appendingPathComponent("install.sh", isDirectory: false)
        let status = try Self.runCoderouterChild(
            executable: "/usr/bin/curl",
            arguments: [
                "--proto", "=https",
                "--tlsv1.2",
                "-fsSL",
                "--max-time", "60",
                Self.coderouterInstallerURL,
                "-o", scriptURL.path,
            ],
            environment: childEnvironment,
            standardInput: FileHandle.nullDevice
        )
        guard status == 0 else {
            try? fileManager.removeItem(at: directory)
            throw Self.coderouterUnavailable(String(
                format: Self.localizedPassthroughString(
                    "cli.coderouter.bootstrap.downloadFailed",
                    defaultValue: "Could not download the CodeRouter installer (curl exited with status %1$d). Retry, or install it with:\n  %2$@"
                ),
                status,
                Self.coderouterInstallCommand
            ))
        }
        return CoderouterInstallerScript(scriptURL: scriptURL, temporaryDirectory: directory)
    }

    /// Runs a bootstrap child on this terminal and waits for it. Returns its
    /// exit status, or 128 plus the signal number when a signal ended it, the
    /// shell convention the user already knows.
    private static func runCoderouterChild(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: FileHandle? = nil
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable, isDirectory: false)
        process.arguments = arguments
        process.environment = environment
        if let standardInput {
            process.standardInput = standardInput
        }
        try cliRunProcess(process)
        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal {
            return 128 + process.terminationStatus
        }
        return process.terminationStatus
    }

    // MARK: - Exec

    /// Replace this process with the CodeRouter CLI so stdin/stdout/stderr,
    /// signals, and the child exit status retain their normal terminal
    /// semantics. The argv is built directly; arguments such as prompts,
    /// paths, and shell metacharacters are never interpreted by a shell.
    private func execCoderouter(
        at executablePath: String,
        commandArgs: [String],
        environment: [String: String]
    ) throws {
        let childEnvironment = Self.coderouterChildEnvironment(from: environment)
        var argv = ([executablePath] + commandArgs).map { strdup($0) }
        let environmentStrings = childEnvironment.keys.sorted().map { key in
            "\(key)=\(childEnvironment[key] ?? "")"
        }
        var environmentPointers = environmentStrings.map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
            for item in environmentPointers {
                free(item)
            }
        }
        argv.append(nil)
        environmentPointers.append(nil)

        let executionError = cliExecFailureErrno {
            executablePath.withCString { executable in
                _ = execve(executable, &argv, &environmentPointers)
            }
        }
        let errorText = String(cString: strerror(executionError))
        cliDebugLog(
            "cli.coderouter.exec_failed executable=\(executablePath) "
                + "errno=\(executionError) error=\(errorText)"
        )
        throw Self.coderouterUnavailable(Self.localizedPassthroughString(
            "cli.coderouter.error.launchFailed",
            defaultValue: "Could not start the required CLI. Check the installation and try again."
        ))
    }

    // MARK: - Presentation

    /// Every way of not running CodeRouter exits 127, the "command not found"
    /// status scripts already handle; the reason is on stderr.
    private static func coderouterUnavailable(_ message: String) -> CLIError {
        CLIError(message: message, exitCode: 127)
    }

    /// An explicit `AppleLanguages` override wins, then the app bundle's
    /// catalog in the user's language, then the English default.
    private static func localizedPassthroughString(_ key: String, defaultValue: String) -> String {
        CMUXDiffViewerLocalization.string(key, defaultValue: defaultValue)
    }
}
