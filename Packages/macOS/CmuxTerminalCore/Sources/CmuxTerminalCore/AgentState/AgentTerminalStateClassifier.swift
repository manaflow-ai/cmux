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
           let direct = catalog.profiles.first(where: { $0.executableBasenames.contains(executable) }) {
            return direct
        }
        if let normalizedPath,
           let pathMatch = catalog.profiles.first(where: { profile in
               profile.argumentNeedles.contains { normalizedPath.contains($0.lowercased()) }
           }) {
            return pathMatch
        }
        guard let executable, Self.argumentWrapperBasenames.contains(executable) else { return nil }
        for key in ["CMUX_AGENT", "CMUX_AGENT_LAUNCH_KIND"] {
            if let hint = process.environment[key], let profile = catalog.profile(hint: hint) {
                return profile
            }
        }
        let command = process.arguments.joined(separator: " ").lowercased()
        return catalog.profiles.first { profile in
            profile.argumentNeedles.contains { command.contains($0.lowercased()) }
        }
    }

    /// Classifies current live-bottom evidence for one recognized generation.
    public func classify(_ snapshot: AgentTerminalScreenSnapshot) -> AgentTerminalStateClassification {
        guard let familyID = snapshot.familyID, let profile = catalog.profile(id: familyID) else {
            return AgentTerminalStateClassification(
                familyID: nil,
                statusKey: nil,
                state: .unknown,
                processIdentity: snapshot.processIdentity
            )
        }
        let text = Self.normalizedVisibleText(snapshot.liveBottomVT)
        let physicalLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let liveBottom = physicalLines.suffix(18).joined(separator: "\n")
        let liveEvidence = String(liveBottom.suffix(48 * 1024))
        let state: AgentTerminalSemanticState
        if profile.historyViewNeedles.contains(where: liveEvidence.contains) {
            state = snapshot.previousReliableState ?? .unknown
        } else if Self.matchesAnyEvidenceGroup(profile.blockedEvidenceGroups, in: liveEvidence) {
            state = .blocked
        } else if Self.matchesAnyEvidenceGroup(profile.workingEvidenceGroups, in: liveEvidence) {
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
            state: state,
            processIdentity: snapshot.processIdentity
        )
    }

    private static func matchesAnyEvidenceGroup(_ groups: [[String]], in evidence: String) -> Bool {
        groups.contains { group in
            !group.isEmpty && group.allSatisfy { evidence.contains($0.lowercased()) }
        }
    }

    private static func normalizedVisibleText(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(min(raw.utf8.count, 48 * 1024))
        var iterator = raw.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                guard let next = iterator.next() else { break }
                if next == "[" {
                    while let control = iterator.next() {
                        if control.value >= 0x40 && control.value <= 0x7E { break }
                    }
                } else if next == "]" {
                    var previous: Unicode.Scalar?
                    while let control = iterator.next() {
                        if control == "\u{7}" || (previous == "\u{1B}" && control == "\\") { break }
                        previous = control
                    }
                }
                continue
            }
            if scalar == "\r" { result.append("\n") }
            else if scalar.value >= 0x20 || scalar == "\n" || scalar == "\t" { result.unicodeScalars.append(scalar) }
        }
        return result.lowercased()
    }
}
