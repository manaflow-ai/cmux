import Foundation

/// Pure recognition and live-bottom classification using a prevalidated catalog.
public struct AgentTerminalStateClassifier: Sendable {
    private let catalog: AgentTerminalProfileCatalog
    private static let argumentWrapperBasenames: Set<String> = [
        "acli", "bun", "deno", "node", "npm", "npx", "pnpm", "python", "python3",
        "sandbox-exec", "ts-node", "tsx", "uv", "uvx", "yarn",
    ]
    private static let wrapperFlagOptionsByBasename: [String: Set<String>] = [
        "npx": [
            "-q", "--ignore-existing", "--no-install", "--offline",
            "--prefer-offline", "--quiet", "--yes", "-y",
        ],
        "uvx": ["--isolated", "--no-cache", "--offline"],
    ]
    private static let wrapperValueOptionsByBasename: [String: Set<String>] = [
        "npx": ["--cache", "--package", "--prefix", "--registry", "--userconfig"],
        "uvx": ["--from", "--python", "--with"],
    ]
    private static let wrapperSubcommandsByBasename: [String: Set<String>] = [
        "bun": ["x"],
        "npm": ["exec", "x"],
        "pnpm": ["dlx", "exec", "x"],
        "yarn": ["dlx", "exec"],
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
        arguments: [String],
        depth: Int = 0
    ) -> AgentTerminalFamilyProfile? {
        guard depth < 4 else { return nil }
        guard let argvZero = arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !argvZero.isEmpty else { return nil }

        // Some Python agents replace argv[0] with a process title such as
        // "Kimi Code". That title is the launch identity, not a prompt.
        let rawTarget: String
        let remainingArguments: ArraySlice<String>
        if URL(fileURLWithPath: argvZero).lastPathComponent.lowercased() != wrapperExecutable {
            rawTarget = argvZero
            remainingArguments = arguments.dropFirst()
        } else {
            let launcherArguments = arguments.dropFirst()
            guard let targetIndex = Self.wrapperTargetIndex(
                wrapperExecutable: wrapperExecutable,
                in: launcherArguments
            ) else { return nil }
            rawTarget = launcherArguments[targetIndex]
            remainingArguments = launcherArguments[launcherArguments.index(after: targetIndex)...]
        }
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let targetBasename = URL(fileURLWithPath: target).lastPathComponent.lowercased()
        if let exact = catalog.profile(
            executableBasename: targetBasename
        ) {
            return exact
        }
        let normalizedTarget = target.lowercased()
        if let argumentMatch = catalog.profiles.first(where: { profile in
            profile.argumentNeedles.contains { normalizedTarget.contains($0.lowercased()) }
        }) {
            return argumentMatch
        }
        guard Self.isArgumentWrapperBasename(targetBasename) else { return nil }
        return wrappedExecutableProfile(
            wrapperExecutable: targetBasename,
            arguments: [target] + Array(remainingArguments),
            depth: depth + 1
        )
    }

    private static func wrapperTargetIndex(
        wrapperExecutable: String,
        in arguments: ArraySlice<String>
    ) -> ArraySlice<String>.Index? {
        let flagOptions = wrapperFlagOptionsByBasename[wrapperExecutable] ?? []
        let valueOptions = wrapperValueOptionsByBasename[wrapperExecutable] ?? []
        let wrapperSubcommands = wrapperSubcommandsByBasename[wrapperExecutable] ?? []
        var skippedWrapperSubcommand = false
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" {
                let targetIndex = arguments.index(after: index)
                return targetIndex < arguments.endIndex ? targetIndex : nil
            }
            if flagOptions.contains(argument) {
                index = arguments.index(after: index)
                continue
            }
            if valueOptions.contains(argument) {
                index = arguments.index(after: index)
                guard index < arguments.endIndex else { return nil }
                index = arguments.index(after: index)
                continue
            }
            if valueOptions.contains(where: { argument.hasPrefix("\($0)=") }) {
                index = arguments.index(after: index)
                continue
            }
            if !skippedWrapperSubcommand, wrapperSubcommands.contains(argument) {
                skippedWrapperSubcommand = true
                index = arguments.index(after: index)
                continue
            }
            return argument.hasPrefix("-") ? nil : index
        }
        return nil
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
