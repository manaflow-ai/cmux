import Foundation

/// Per-process-snapshot index of Pi-family session files. A refresh sees a
/// coherent directory snapshot and never walks the same project tree once per
/// live agent process. The next refresh constructs a fresh index, so newly
/// written sessions are visible without a TTL or invalidation timer.
struct PiSessionDirectoryIndex {
    private struct Candidate {
        let url: URL
        let modifiedAt: Date
    }

    private struct DirectorySnapshot {
        let candidates: [Candidate]
        let newest: Candidate?
        let exactByBasename: [String: Candidate]
    }

    private enum CachedDirectory {
        case unavailable
        case files(DirectorySnapshot)
    }

    private let fileManager: FileManager
    private var cachedDirectories: [String: CachedDirectory] = [:]
    private(set) var directoryEnumerationCount = 0
    private(set) var candidateQueryVisitCount = 0

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    mutating func newestJSONLFile(in directory: String) -> URL? {
        directorySnapshot(in: directory)?.newest?.url
    }

    mutating func resolvedSessionPath(_ session: String, in directory: String) -> String? {
        guard let snapshot = directorySnapshot(in: directory) else { return nil }
        if let exact = snapshot.exactByBasename[session] {
            return exact.url.path
        }

        var partialNewest: Candidate?
        for candidate in snapshot.candidates {
            candidateQueryVisitCount += 1
            let basename = candidate.url.deletingPathExtension().lastPathComponent
            guard basename.contains(session) else { continue }
            if Self.isPreferred(candidate, over: partialNewest) {
                partialNewest = candidate
            }
        }
        return partialNewest?.url.path
    }

    private mutating func directorySnapshot(in directory: String) -> DirectorySnapshot? {
        let standardizedDirectory = (directory as NSString).standardizingPath
        if let cached = cachedDirectories[standardizedDirectory] {
            switch cached {
            case .unavailable:
                return nil
            case .files(let snapshot):
                return snapshot
            }
        }

        directoryEnumerationCount += 1
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: URL(fileURLWithPath: standardizedDirectory, isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            cachedDirectories[standardizedDirectory] = .unavailable
            return nil
        }

        var candidates: [Candidate] = []
        var newest: Candidate?
        var exactByBasename: [String: Candidate] = [:]
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate else {
                continue
            }
            let candidate = Candidate(url: url, modifiedAt: modifiedAt)
            candidates.append(candidate)
            if Self.isPreferred(candidate, over: newest) {
                newest = candidate
            }
            let basename = url.deletingPathExtension().lastPathComponent
            if Self.isPreferred(candidate, over: exactByBasename[basename]) {
                exactByBasename[basename] = candidate
            }
        }
        let snapshot = DirectorySnapshot(
            candidates: candidates,
            newest: newest,
            exactByBasename: exactByBasename
        )
        cachedDirectories[standardizedDirectory] = .files(snapshot)
        return snapshot
    }

    /// Prefer a newer file, then the lexicographically first path when mtimes
    /// tie. Directory enumeration order is filesystem-dependent.
    private static func isPreferred(_ candidate: Candidate, over current: Candidate?) -> Bool {
        guard let current else { return true }
        if candidate.modifiedAt != current.modifiedAt {
            return candidate.modifiedAt > current.modifiedAt
        }
        return candidate.url.path < current.url.path
    }
}

extension PiSessionLocator {
    static func candidateSessionDirectory(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
    ) -> String {
        let sessionRoot = process.arguments.sessionDirectoryValue(afterOption: "--session-dir")
            ?? piConfiguredSessionDirectory(for: process, registration: registration)
            ?? configuredSessionDirectory(for: registration)
            ?? ompAgentSessionsRoot(for: process, registration: registration)
            ?? campfireAgentSessionsRoot(for: process, registration: registration)
            ?? registration.sessionDirectory
            ?? defaultSessionsRoot()
        let expandedRoot = (sessionRoot as NSString).expandingTildeInPath
        if let cwd = process.environment["CMUX_AGENT_LAUNCH_CWD"] ?? process.environment["PWD"],
           let projectDirectory = projectDirectoryName(for: cwd) {
            return (expandedRoot as NSString).appendingPathComponent(projectDirectory)
        }
        return expandedRoot
    }

    /// Reads `PI_CODING_AGENT_SESSION_DIR` for Pi-based agents only.
    ///
    /// Campfire embeds Pi, so a Campfire process can inherit
    /// `PI_CODING_AGENT_SESSION_DIR` from a user's Pi configuration. Consuming it
    /// here would resolve Campfire sessions against the Pi session directory and
    /// pre-empt Campfire's own `CAMPFIRE_CODING_AGENT_SESSION_DIR` /
    /// `CAMPFIRE_CODING_AGENT_DIR` lookup, so it is gated out for the `campfire`
    /// registration. Behavior for `pi` and `omp` is unchanged.
    static func piConfiguredSessionDirectory(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
    ) -> String? {
        guard registration.id != "campfire" else { return nil }
        return process.environment["PI_CODING_AGENT_SESSION_DIR"]
    }

    static func ompAgentSessionsRoot(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
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

    static func campfireAgentSessionsRoot(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
    ) -> String? {
        guard registration.id == "campfire" else { return nil }
        if let sessionRoot = nonEmptyEnvironmentValue("CAMPFIRE_CODING_AGENT_SESSION_DIR", in: process.environment) {
            return NSString(string: sessionRoot).expandingTildeInPath
        }
        guard let agentRoot = nonEmptyEnvironmentValue("CAMPFIRE_CODING_AGENT_DIR", in: process.environment) else {
            return nil
        }
        let expandedAgentRoot = NSString(string: agentRoot).expandingTildeInPath
        return (expandedAgentRoot as NSString).appendingPathComponent("sessions")
    }

    static func configuredSessionDirectory(for registration: CmuxVaultAgentRegistration) -> String? {
        guard let sessionDirectory = registration.sessionDirectory else { return nil }
        if registration.id == "omp",
           sessionDirectory == CmuxVaultAgentRegistration.builtInOmp.sessionDirectory {
            return nil
        }
        if registration.id == "campfire",
           sessionDirectory == CmuxVaultAgentRegistration.builtInCampfire.sessionDirectory {
            return nil
        }
        return sessionDirectory
    }

    static func nonEmptyEnvironmentValue(_ name: String, in environment: [String: String]) -> String? {
        let trimmed = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}

private extension Array where Element == String {
    func sessionDirectoryValue(afterOption option: String) -> String? {
        for index in indices {
            let argument = self[index]
            if argument == option {
                let nextIndex = self.index(after: index)
                guard nextIndex < endIndex else { return nil }
                let value = self[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            let prefix = option + "="
            if argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
