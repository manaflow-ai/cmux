import Foundation

/// Resolves the on-disk locations of pi-style (`pi`/`omp`) agent session files
/// for a registered agent, given an observed process and a `FileManager`.
///
/// The locator reads the session-root configuration from the observed process
/// (`--session-dir` argv, `PI_CODING_AGENT_SESSION_DIR`/`PI_CODING_AGENT_DIR`/`PI_CONFIG_DIR`
/// environment) and from the agent registration. The registration inputs that
/// originate in the app (`CmuxVaultAgentRegistration.id`/`.sessionDirectory`, and the
/// built-in `omp` registration's session directory) are passed in per call as plain
/// values, so this type carries no dependency on app-side registration types. Stateless
/// path helpers are exposed as `static` members.
public struct PiSessionLocator: Sendable {
    // `FileManager` is not `Sendable`, but `FileManager.default` is documented as
    // thread-safe and the only value injected here; `nonisolated(unsafe) let` is the
    // sanctioned escape hatch for an immutable, effectively-Sendable stored property.
    nonisolated(unsafe) let fileManager: FileManager

    /// Creates a locator bound to a `FileManager` (defaulting to the shared instance).
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The default pi session root (`~/.pi/agent/sessions`) under the given home directory.
    static func defaultSessionsRoot(homeDirectory: String = NSHomeDirectory()) -> String {
        let standardizedHome = (homeDirectory as NSString).standardizingPath
        return (standardizedHome as NSString).appendingPathComponent(".pi/agent/sessions")
    }

    /// The per-project session subdirectory name pi derives from a working directory
    /// (leading slash dropped, `/` and `:` replaced with `-`, wrapped in `--…--`), or
    /// `nil` when the working directory is empty.
    public static func projectDirectoryName(for workingDirectory: String) -> String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutLeadingSlash = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let sanitized = withoutLeadingSlash
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !sanitized.isEmpty else { return nil }
        return "--\(sanitized)--"
    }

    /// The newest `.jsonl` session file path in the candidate session directory for the
    /// observed process, or `nil` when none exists.
    ///
    /// - Parameters:
    ///   - process: The observed agent process whose argv/environment select the session root.
    ///   - registrationID: The agent registration id (`registration.id`).
    ///   - registrationSessionDirectory: The registration's configured session directory
    ///     (`registration.sessionDirectory`).
    ///   - builtInOmpSessionDirectory: The built-in `omp` registration's session directory,
    ///     used to detect an unmodified default `omp` configuration.
    public func latestSessionPath(
        for process: VaultObservedAgentProcess,
        registrationID: String,
        registrationSessionDirectory: String?,
        builtInOmpSessionDirectory: String?
    ) -> String? {
        newestJSONLFile(in: Self.candidateSessionDirectory(
            for: process,
            registrationID: registrationID,
            registrationSessionDirectory: registrationSessionDirectory,
            builtInOmpSessionDirectory: builtInOmpSessionDirectory
        ))?.path
    }

    /// Resolves an explicit pi session id to a concrete session file path: an absolute/tilde
    /// path is returned as-is (expanded when it exists), otherwise the candidate session
    /// directory is scanned for an exact-then-partial basename match, preferring the newest.
    ///
    /// - Parameters:
    ///   - session: The session id or path captured from the process.
    ///   - process: The observed agent process whose argv/environment select the session root.
    ///   - registrationID: The agent registration id (`registration.id`).
    ///   - registrationSessionDirectory: The registration's configured session directory
    ///     (`registration.sessionDirectory`).
    ///   - builtInOmpSessionDirectory: The built-in `omp` registration's session directory,
    ///     used to detect an unmodified default `omp` configuration.
    public func resolvedSessionPath(
        _ session: String,
        for process: VaultObservedAgentProcess,
        registrationID: String,
        registrationSessionDirectory: String?,
        builtInOmpSessionDirectory: String?
    ) -> String? {
        let trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return fileManager.fileExists(atPath: expanded) ? expanded : trimmed
        }

        let directory = Self.candidateSessionDirectory(
            for: process,
            registrationID: registrationID,
            registrationSessionDirectory: registrationSessionDirectory,
            builtInOmpSessionDirectory: builtInOmpSessionDirectory
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: URL(fileURLWithPath: directory, isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var exactNewest: (url: URL, modified: Date)?
        var partialNewest: (url: URL, modified: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let basename = url.deletingPathExtension().lastPathComponent
            guard basename == trimmed || basename.contains(trimmed) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            if basename == trimmed {
                if exactNewest == nil || modified > exactNewest!.modified {
                    exactNewest = (url, modified)
                }
            } else if partialNewest == nil || modified > partialNewest!.modified {
                partialNewest = (url, modified)
            }
        }
        return exactNewest?.url.path ?? partialNewest?.url.path
    }

    private static func candidateSessionDirectory(
        for process: VaultObservedAgentProcess,
        registrationID: String,
        registrationSessionDirectory: String?,
        builtInOmpSessionDirectory: String?
    ) -> String {
        let sessionRoot = AgentResumeArgvParser().value(in: process.arguments, afterOption: "--session-dir")
            ?? process.environment["PI_CODING_AGENT_SESSION_DIR"]
            ?? configuredSessionDirectory(
                registrationID: registrationID,
                registrationSessionDirectory: registrationSessionDirectory,
                builtInOmpSessionDirectory: builtInOmpSessionDirectory
            )
            ?? ompAgentSessionsRoot(for: process, registrationID: registrationID)
            ?? registrationSessionDirectory
            ?? defaultSessionsRoot()
        let expandedRoot = (sessionRoot as NSString).expandingTildeInPath
        if let cwd = process.environment["CMUX_AGENT_LAUNCH_CWD"] ?? process.environment["PWD"],
           let projectDirectory = projectDirectoryName(for: cwd) {
            return (expandedRoot as NSString).appendingPathComponent(projectDirectory)
        }
        return expandedRoot
    }

    private static func ompAgentSessionsRoot(
        for process: VaultObservedAgentProcess,
        registrationID: String
    ) -> String? {
        guard registrationID == "omp" else { return nil }
        if let agentRoot = nonEmptyEnvironmentValue("PI_CODING_AGENT_DIR", in: process.environment) {
            let expandedAgentRoot = NSString(string: agentRoot).expandingTildeInPath
            return (expandedAgentRoot as NSString).appendingPathComponent("sessions")
        }
        guard let configDir = nonEmptyEnvironmentValue("PI_CONFIG_DIR", in: process.environment) else {
            return nil
        }
        let home = nonEmptyEnvironmentValue("HOME", in: process.environment) ?? NSHomeDirectory()
        let expandedConfigDir = NSString(string: configDir).expandingTildeInPath
        let configRoot: String
        if (expandedConfigDir as NSString).isAbsolutePath {
            configRoot = expandedConfigDir
        } else {
            configRoot = ((NSString(string: home).expandingTildeInPath) as NSString)
                .appendingPathComponent(configDir)
        }
        let agentRoot = (configRoot as NSString).appendingPathComponent("agent")
        return (agentRoot as NSString).appendingPathComponent("sessions")
    }

    private static func configuredSessionDirectory(
        registrationID: String,
        registrationSessionDirectory: String?,
        builtInOmpSessionDirectory: String?
    ) -> String? {
        guard let sessionDirectory = registrationSessionDirectory else { return nil }
        if registrationID == "omp",
           sessionDirectory == builtInOmpSessionDirectory {
            return nil
        }
        return sessionDirectory
    }

    private static func nonEmptyEnvironmentValue(_ name: String, in environment: [String: String]) -> String? {
        let trimmed = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func newestJSONLFile(in directory: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: URL(fileURLWithPath: directory, isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        return newest?.url
    }
}
