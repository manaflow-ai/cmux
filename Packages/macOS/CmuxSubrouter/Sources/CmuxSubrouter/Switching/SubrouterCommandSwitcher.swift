public import Foundation
public import CmuxFoundation
import Darwin
import os

/// The production ``SubrouterAccountSwitching``: runs the `sr` CLI through
/// the shared ``CmuxFoundation/CommandRunning`` seam.
///
/// Binary resolution order: the explicit `commandPath` setting when present;
/// otherwise `sr` then `subrouter` resolved against `PATH` plus the standard
/// install locations (`~/bin`, Homebrew paths). Only the account id crosses
/// the process boundary — never any credential material.
public struct SubrouterCommandSwitcher: SubrouterAccountSwitching {
    private static let bundledSubrouterInstallMaxAge: TimeInterval = 30 * 24 * 60 * 60
    private static let bundledSubrouterLastUsedMarker = ".cmux-last-used"

    private nonisolated static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "SubrouterCommandSwitcher"
    )

    /// Deadline for one `sr` invocation (it may refresh a token upstream).
    public static let commandTimeout: TimeInterval = 30

    private let commandRunner: any EnvironmentCommandRunning
    private let workingDirectory: String

    /// Creates the production switcher.
    /// - Parameters:
    ///   - commandRunner: The subprocess seam; defaults to a runner whose
    ///     fallback search path includes `~/bin` (the subrouter installer's
    ///     non-root default) after the standard Homebrew locations.
    ///   - workingDirectory: The working directory for `sr`; defaults to the
    ///     user's home directory.
    public init(
        commandRunner: (any EnvironmentCommandRunning)? = nil,
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
                    Self.bundledSubrouterInstallDirectory.path,
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
            result = await commandRunner.run(
                directory: workingDirectory,
                executable: executable,
                arguments: arguments,
                timeout: Self.commandTimeout,
                environmentOverrides: environmentOverrides
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
            "CLAUDE_", "ANTHROPIC_", "OPENAI_", "XDG_",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy"
        ]
        return ProcessInfo.processInfo.environment.filter { key, _ in
            allowedPrefixes.contains { prefix in
                prefix.hasSuffix("_") ? key.hasPrefix(prefix) : key == prefix
            }
        }
    }

    /// Extracts the app-bundled binary into the same tag-scoped Application
    /// Support directory searched by the default ``CommandRunner``.
    /// User-installed binaries still win; this is only a fallback for a
    /// pristine install.
    private static func ensureBundledSubrouter() -> String? {
        guard let archiveURL = Bundle.main.url(
            forResource: "subrouter",
            withExtension: "gz",
            subdirectory: "bin"
        ) else { return nil }
        let fileManager = FileManager.default
        let installDirectory = bundledSubrouterInstallDirectory
        pruneBundledSubrouterInstallDirectories(excluding: installDirectory)
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
                // `rename` atomically replaces the previous managed binary;
                // never create a window where concurrent tagged apps see no
                // executable if publication fails.
                guard rename(stagingURL.path, binaryURL.path) == 0 else {
                    return nil
                }
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
        markBundledSubrouterUse(in: installDirectory)
        return fileManager.isExecutableFile(atPath: personaURL.path) ? personaURL.path : nil
    }

    private static func pruneBundledSubrouterInstallDirectories(excluding current: URL) {
        let root = fileManagerApplicationSupportDirectory()
            .appendingPathComponent("cmux/bin", isDirectory: true)
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-bundledSubrouterInstallMaxAge)
        for entry in entries where entry.lastPathComponent.hasPrefix("scope-") {
            guard entry.standardizedFileURL != current.standardizedFileURL,
                  let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let modified = bundledSubrouterLastUsedDate(for: entry, fileManager: fileManager),
                  modified < cutoff else { continue }
            let isExtracting = (try? fileManager.contentsOfDirectory(atPath: entry.path))?
                .contains { $0.hasPrefix(".subrouter.extracting.") } == true
            guard !isExtracting else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func markBundledSubrouterUse(in directory: URL) {
        let marker = directory.appendingPathComponent(bundledSubrouterLastUsedMarker)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: marker.path) {
            _ = fileManager.createFile(atPath: marker.path, contents: Data())
        }
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: marker.path
        )
    }

    private static func bundledSubrouterLastUsedDate(
        for directory: URL,
        fileManager: FileManager
    ) -> Date? {
        let marker = directory.appendingPathComponent(bundledSubrouterLastUsedMarker)
        let path = fileManager.fileExists(atPath: marker.path) ? marker.path : directory.path
        return (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Mirrors the CLI extraction layout so the app's switcher and `cmux sr`
    /// resolve the same immutable binary for a given tagged app.
    private static var bundledSubrouterInstallDirectory: URL {
        let root = fileManagerApplicationSupportDirectory()
            .appendingPathComponent("cmux/bin", isDirectory: true)
        let environment = ProcessInfo.processInfo.environment
        let raw = [
            environment["CMUX_TAG"],
            environment["CMUX_BUNDLE_ID"],
            Bundle.main.bundleIdentifier,
            "stable",
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "stable"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let mapped = raw.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        var scope = String(mapped).replacingOccurrences(
            of: "-+",
            with: "-",
            options: .regularExpression
        )
        scope = scope.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        if scope.isEmpty { scope = "stable" }
        return root.appendingPathComponent("scope-" + String(scope.prefix(96)), isDirectory: true)
    }

    private static func fileManagerApplicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
