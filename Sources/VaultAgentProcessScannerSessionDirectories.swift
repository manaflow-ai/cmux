import Foundation

/// Per-process-snapshot index of Pi-family session files. A refresh sees a
/// coherent directory snapshot and never walks the same project tree once per
/// live agent process. The next refresh constructs a fresh index, so newly
/// written sessions are visible without a TTL or invalidation timer.
struct PiSessionDirectoryIndex {
    private struct Candidate {
        let url: URL
    }

    private enum CandidateResolution {
        case none
        case unique(Candidate)
        case ambiguous

        var candidate: Candidate? {
            guard case .unique(let candidate) = self else { return nil }
            return candidate
        }

        static func merging(_ lhs: CandidateResolution, _ rhs: CandidateResolution) -> CandidateResolution {
            switch (lhs, rhs) {
            case (.ambiguous, _), (_, .ambiguous):
                return .ambiguous
            case (.none, let resolution), (let resolution, .none):
                return resolution
            case (.unique(let lhs), .unique(let rhs)):
                return lhs.url.path == rhs.url.path ? .unique(lhs) : .ambiguous
            }
        }
    }

    private struct DirectorySnapshot {
        let exactByBasename: [String: CandidateResolution]
        let prefixLookup: PrefixLookupIndex
    }

    /// Pi accepts a prefix of its UUID session ID. Session filenames add
    /// a timestamp before that UUID, so both the basename and UUID suffix are
    /// searchable keys. A segment tree resolves a prefix only when every
    /// matching key names the same file, without scanning every candidate.
    private struct PrefixLookupIndex {
        private struct Entry {
            let key: String
            let candidate: Candidate
        }

        private let entries: [Entry]
        private let leafBase: Int
        private let resolutionByTreeNode: [CandidateResolution]

        init(candidates: [Candidate]) {
            var entries: [Entry] = []
            entries.reserveCapacity(candidates.count * 2)
            for candidate in candidates {
                let basename = candidate.url.deletingPathExtension().lastPathComponent
                entries.append(Entry(key: basename, candidate: candidate))
                if let sessionID = Self.uuidSuffix(in: basename) {
                    entries.append(Entry(key: sessionID, candidate: candidate))
                }
            }
            entries.sort { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key < rhs.key }
                return lhs.candidate.url.path < rhs.candidate.url.path
            }
            self.entries = entries

            var leafBase = 1
            while leafBase < entries.count { leafBase *= 2 }
            self.leafBase = leafBase
            var tree = [CandidateResolution](repeating: .none, count: leafBase * 2)
            for (index, entry) in entries.enumerated() {
                tree[leafBase + index] = .unique(entry.candidate)
            }
            if leafBase > 1 {
                for index in stride(from: leafBase - 1, through: 1, by: -1) {
                    tree[index] = CandidateResolution.merging(tree[index * 2], tree[index * 2 + 1])
                }
            }
            self.resolutionByTreeNode = tree
        }

        func uniqueCandidate(forPrefix prefix: String) -> (candidate: Candidate?, visitCount: Int) {
            var lower = 0
            var upper = entries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if entries[middle].key < prefix {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower < entries.count, entries[lower].key.hasPrefix(prefix) else {
                return (nil, 0)
            }

            let rangeStart = lower
            upper = entries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if entries[middle].key.hasPrefix(prefix) {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }

            var left = leafBase + rangeStart
            var right = leafBase + lower
            var resolution = CandidateResolution.none
            var visitCount = 0
            while left < right {
                if left % 2 == 1 {
                    resolution = CandidateResolution.merging(resolution, resolutionByTreeNode[left])
                    visitCount += 1
                    left += 1
                }
                if right % 2 == 1 {
                    right -= 1
                    resolution = CandidateResolution.merging(resolution, resolutionByTreeNode[right])
                    visitCount += 1
                }
                left /= 2
                right /= 2
            }
            return (resolution.candidate, visitCount)
        }

        private static func uuidSuffix(in basename: String) -> String? {
            guard let separator = basename.lastIndex(of: "_") else { return nil }
            let suffix = String(basename[basename.index(after: separator)...])
            return UUID(uuidString: suffix) == nil ? nil : suffix
        }
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

    mutating func resolvedSessionPath(_ session: String, in directory: String) -> String? {
        guard let snapshot = directorySnapshot(in: directory) else { return nil }
        if let exact = snapshot.exactByBasename[session] {
            return exact.candidate?.url.path
        }

        let lookup = snapshot.prefixLookup.uniqueCandidate(forPrefix: session)
        candidateQueryVisitCount += lookup.visitCount
        return lookup.candidate?.url.path
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
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            cachedDirectories[standardizedDirectory] = .unavailable
            return nil
        }

        var candidates: [Candidate] = []
        var exactByBasename: [String: CandidateResolution] = [:]
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                continue
            }
            let candidate = Candidate(url: url)
            candidates.append(candidate)
            let basename = url.deletingPathExtension().lastPathComponent
            exactByBasename[basename] = CandidateResolution.merging(
                exactByBasename[basename] ?? .none,
                .unique(candidate)
            )
        }
        let snapshot = DirectorySnapshot(
            exactByBasename: exactByBasename,
            prefixLookup: PrefixLookupIndex(candidates: candidates)
        )
        cachedDirectories[standardizedDirectory] = .files(snapshot)
        return snapshot
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
