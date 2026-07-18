import Foundation

/// Pure recognition and live-bottom classification using a prevalidated catalog.
public struct AgentTerminalStateClassifier: Sendable {
    private let catalog: AgentTerminalProfileCatalog
    private static let argumentWrapperBasenames: Set<String> = [
        "bun", "deno", "node", "npm", "npx", "pnpm", "python", "python3",
        "sandbox-exec", "ts-node", "tsx", "uv", "uvx", "yarn",
    ]
    private static let shellBasenames: Set<String> = ["bash", "fish", "nu", "sh", "zsh"]

    /// Creates a classifier that reuses a catalog across evaluations.
    public init(catalog: AgentTerminalProfileCatalog = .builtIn) {
        self.catalog = catalog
    }

    /// Recognizes the foreground process, including generic runtime wrappers and cmux hints.
    public func recognize(_ process: AgentTerminalProcessSnapshot) -> AgentTerminalFamilyProfile? {
        let normalizedPath = process.executablePath?.lowercased()
        let executable = normalizedPath.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
        if executable == "tmux" || executable.map(Self.shellBasenames.contains) == true { return nil }
        if let executable,
           let direct = catalog.profile(executableBasename: executable) {
            return direct
        }
        if let normalizedPath,
           let pathMatch = catalog.profiles.first(where: { profile in
               profile.argumentNeedles.contains { normalizedPath.contains($0.lowercased()) }
           }) {
            return pathMatch
        }
        guard let executable, Self.isArgumentWrapperBasename(executable) else { return nil }
        if let profile = wrappedExecutableProfile(
            wrapperExecutable: executable,
            arguments: process.arguments
        ) {
            return profile
        }
        for key in ["CMUX_AGENT", "CMUX_AGENT_LAUNCH_KIND"] {
            if let hint = process.environment[key], let profile = catalog.profile(hint: hint) {
                return profile
            }
        }
        return nil
    }

    /// Generic runtimes often remain the foreground process while their launch
    /// target names the real agent executable. Inspect that one path only.
    /// Later arguments may be subcommands, file paths, or user prompt text.
    private func wrappedExecutableProfile(
        wrapperExecutable: String,
        arguments: [String]
    ) -> AgentTerminalFamilyProfile? {
        guard let argvZero = arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !argvZero.isEmpty else { return nil }

        // Some Python agents replace argv[0] with a process title such as
        // "Kimi Code". That title is the launch identity, not a prompt.
        let rawTarget: String
        if URL(fileURLWithPath: argvZero).lastPathComponent.lowercased() != wrapperExecutable {
            rawTarget = argvZero
        } else {
            let launcherArguments = arguments.dropFirst()
            guard let first = launcherArguments.first else { return nil }
            if first == "--" {
                guard launcherArguments.count > 1 else { return nil }
                rawTarget = launcherArguments[launcherArguments.index(after: launcherArguments.startIndex)]
            } else {
                guard !first.hasPrefix("-") else { return nil }
                rawTarget = first
            }
        }
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        if let exact = catalog.profile(
            executableBasename: URL(fileURLWithPath: target).lastPathComponent.lowercased()
        ) {
            return exact
        }
        let normalizedTarget = target.lowercased()
        return catalog.profiles.first { profile in
            profile.argumentNeedles.contains { normalizedTarget.contains($0.lowercased()) }
        }
    }

    private static func isArgumentWrapperBasename(_ executable: String) -> Bool {
        if argumentWrapperBasenames.contains(executable) { return true }
        guard executable.hasPrefix("python") else { return false }
        let version = executable.dropFirst("python".count)
        guard !version.isEmpty else { return false }
        return version.contains(where: \.isNumber)
            && version.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Classifies bounded plain-text evidence for one recognized generation.
    public func classify(_ snapshot: AgentTerminalScreenSnapshot) -> AgentTerminalStateClassification {
        guard let familyID = snapshot.familyID, let profile = catalog.profile(id: familyID) else {
            return AgentTerminalStateClassification(
                familyID: nil,
                statusKey: nil,
                sessionProviderID: nil,
                state: .unknown,
                processIdentity: snapshot.processIdentity
            )
        }
        let liveEvidence = snapshot.liveBottomText.lowercased()
        let workingEvidence = Self.bottomRows(liveEvidence, maximumRows: 12)
        let state: AgentTerminalSemanticState
        if profile.historyViewNeedles.contains(where: liveEvidence.contains) {
            state = snapshot.previousReliableState ?? .unknown
        } else if Self.matchesAnyEvidenceGroup(profile.blockedEvidenceGroups, in: liveEvidence)
                    || Self.matchesAnyExactLine(profile.blockedExactLines, in: liveEvidence) {
            state = .blocked
        } else if Self.matchesAnyEvidenceGroup(profile.workingEvidenceGroups, in: workingEvidence) {
            state = .working
        } else {
            // An explicit idle marker and a known-agent fallback have the same
            // semantic result. Keeping both in profile data lets diagnostics
            // distinguish strong evidence later without changing the contract.
            state = .idle
        }
        return AgentTerminalStateClassification(
            familyID: profile.id,
            statusKey: profile.statusKey,
            sessionProviderID: profile.sessionProviderID,
            lifecycleAuthoritative: profile.lifecycleAuthoritative,
            state: state,
            processIdentity: snapshot.processIdentity
        )
    }

    private static func matchesAnyEvidenceGroup(_ groups: [[String]], in evidence: String) -> Bool {
        groups.contains { group in
            !group.isEmpty && group.allSatisfy { evidence.contains($0.lowercased()) }
        }
    }

    private static func matchesAnyExactLine(_ needles: [String], in evidence: String) -> Bool {
        guard !needles.isEmpty else { return false }
        let lines = evidence.split(whereSeparator: \Character.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return needles.contains { needle in lines.contains(needle) }
    }

    private static func bottomRows(_ evidence: String, maximumRows: Int) -> String {
        guard maximumRows > 0 else { return "" }
        var rowStart = evidence.endIndex
        var newlineCount = 0
        while rowStart > evidence.startIndex {
            let previous = evidence.index(before: rowStart)
            if evidence[previous] == "\n" {
                newlineCount += 1
                if newlineCount == maximumRows {
                    return String(evidence[rowStart...])
                }
            }
            rowStart = previous
        }
        return evidence
    }

}
