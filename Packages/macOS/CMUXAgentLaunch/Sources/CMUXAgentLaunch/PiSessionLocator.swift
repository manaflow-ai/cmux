public import Foundation

/// The process- and registration-coupled inputs `PiSessionLocator` needs from a
/// `pi`-compatible agent's registration, lifted out of the app-side registry type
/// so the package never imports it.
///
/// Carries only the three fields the locator reads: the registration `id` (used
/// to special-case `omp` roots), the configured `sessionDirectory`, and the
/// built-in omp default `sessionDirectory` (compared against to detect a
/// registration that merely inherited the default omp directory). All `Sendable`
/// value types, so it crosses isolation freely.
public struct PiSessionRegistration: Sendable, Equatable {
    /// The registration identifier (e.g. `"pi"`, `"omp"`).
    public let id: String

    /// The registration's configured session directory, if any.
    public let sessionDirectory: String?

    /// The built-in omp registration's default session directory, used to detect
    /// a registration that merely inherited the omp default rather than
    /// configuring its own directory.
    public let builtInOmpSessionDirectory: String?

    /// Creates a registration value.
    ///
    /// - Parameters:
    ///   - id: The registration identifier.
    ///   - sessionDirectory: The configured session directory, if any.
    ///   - builtInOmpSessionDirectory: The built-in omp default session directory.
    public init(
        id: String,
        sessionDirectory: String?,
        builtInOmpSessionDirectory: String?
    ) {
        self.id = id
        self.sessionDirectory = sessionDirectory
        self.builtInOmpSessionDirectory = builtInOmpSessionDirectory
    }
}

/// Resolver for the process- and registration-coupled pieces of a
/// `pi`-compatible agent's session layout. Selects the candidate session
/// directory from argv/env overrides, omp-specific roots, and the registration's
/// configured directory, then forwards the pure path/file math
/// (`projectDirectoryName`, `defaultSessionsRoot`, `newestJSONLFile`) to the
/// process-independent `PiSessionResolver`.
///
/// Lives beside `PiSessionResolver`: this type owns the impure directory
/// selection (env overrides, omp roots, configured directories) that needs a
/// `VaultObservedAgentProcess` and a registration, while `PiSessionResolver`
/// owns the pure path math. The app injects the registration as a
/// `PiSessionRegistration` value so the package does not depend on the app
/// registry type.
public struct PiSessionLocator {
    private let fileManager: FileManager
    private let resolver: PiSessionResolver

    /// Creates a locator.
    ///
    /// - Parameter fileManager: Injected so tests can point resolution at a
    ///   temporary sessions tree; defaults to `.default`.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.resolver = PiSessionResolver(fileManager: fileManager)
    }

    /// The path of the newest `.jsonl` rollout in the candidate session
    /// directory for `process` and `registration`, or `nil` when none exists.
    ///
    /// - Parameters:
    ///   - process: The observed agent process supplying argv/env overrides.
    ///   - registration: The registration's session-layout inputs.
    public func latestSessionPath(
        for process: VaultObservedAgentProcess,
        registration: PiSessionRegistration
    ) -> String? {
        resolver.newestJSONLFile(in: candidateSessionDirectory(for: process, registration: registration))?.path
    }

    /// Resolves an explicit `session` identifier (or path) to an on-disk rollout
    /// path for `process` and `registration`, preferring an exact basename match
    /// over a partial one, or `nil` when nothing matches.
    ///
    /// A `session` containing `/` is treated as a path: it is tilde-expanded and
    /// returned if it exists, else returned verbatim. Otherwise the candidate
    /// session directory is scanned for `.jsonl` files whose basename equals or
    /// contains `session`, newest by modification date.
    ///
    /// - Parameters:
    ///   - session: The session identifier or path to resolve.
    ///   - process: The observed agent process supplying argv/env overrides.
    ///   - registration: The registration's session-layout inputs.
    public func resolvedSessionPath(
        _ session: String,
        for process: VaultObservedAgentProcess,
        registration: PiSessionRegistration
    ) -> String? {
        let trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return fileManager.fileExists(atPath: expanded) ? expanded : trimmed
        }

        let directory = candidateSessionDirectory(for: process, registration: registration)
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

    private func candidateSessionDirectory(
        for process: VaultObservedAgentProcess,
        registration: PiSessionRegistration
    ) -> String {
        let sessionRoot = process.arguments.value(afterOption: "--session-dir")
            ?? process.environment["PI_CODING_AGENT_SESSION_DIR"]
            ?? configuredSessionDirectory(for: registration)
            ?? ompAgentSessionsRoot(for: process, registration: registration)
            ?? registration.sessionDirectory
            ?? resolver.defaultSessionsRoot()
        let expandedRoot = (sessionRoot as NSString).expandingTildeInPath
        if let cwd = process.environment["CMUX_AGENT_LAUNCH_CWD"] ?? process.environment["PWD"],
           let projectDirectory = resolver.projectDirectoryName(for: cwd) {
            return (expandedRoot as NSString).appendingPathComponent(projectDirectory)
        }
        return expandedRoot
    }

    private func ompAgentSessionsRoot(
        for process: VaultObservedAgentProcess,
        registration: PiSessionRegistration
    ) -> String? {
        guard registration.id == "omp" else { return nil }
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

    private func configuredSessionDirectory(for registration: PiSessionRegistration) -> String? {
        guard let sessionDirectory = registration.sessionDirectory else { return nil }
        if registration.id == "omp",
           sessionDirectory == registration.builtInOmpSessionDirectory {
            return nil
        }
        return sessionDirectory
    }

    private func nonEmptyEnvironmentValue(_ name: String, in environment: [String: String]) -> String? {
        let trimmed = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
