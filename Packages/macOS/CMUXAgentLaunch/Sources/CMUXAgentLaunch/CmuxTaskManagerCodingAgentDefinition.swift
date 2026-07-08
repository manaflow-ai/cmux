import Foundation

/// Value model describing a known coding agent for the Task Manager surface, plus the
/// process-detection API that maps a running process (name/path/arguments/environment)
/// to its agent definition. Holds the built-in registry of supported agents.
public struct CmuxTaskManagerCodingAgentDefinition: Equatable, Sendable {
    /// Stable identifier for the agent (e.g. `"claude"`, `"codex"`).
    public let id: String
    /// Human-readable name shown in the Task Manager (e.g. `"Claude Code"`).
    public let displayName: String
    /// Asset catalog name for the agent icon, or `nil` when no icon is bundled.
    public let assetName: String?
    public let launchKinds: [String]
    public let directBasenames: [String]
    public let argumentNeedles: [String]

    /// The registry of all coding agents the Task Manager can detect.
    public static let builtIns: [CmuxTaskManagerCodingAgentDefinition] = [
        CmuxTaskManagerCodingAgentDefinition(
            id: "claude",
            displayName: "Claude Code",
            assetName: "AgentIcons/Claude",
            launchKinds: ["claude", "claudeteams", "claude-teams", "omc"],
            directBasenames: ["claude", "claude.exe", "claude-code", "claude_code", "claude-teams", "omc"],
            argumentNeedles: [
                "claude-code",
                "claude_code",
                "claude-teams",
                "@anthropic-ai/claude-code",
                "oh-my-claude",
                "omc",
                "/.local/bin/claude",
                "/.local/share/claude/versions/",
                "/library/application support/claude/claude-code/",
            ]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "codex",
            displayName: "Codex",
            assetName: "AgentIcons/Codex",
            launchKinds: ["codex", "omx"],
            directBasenames: ["codex", "omx"],
            argumentNeedles: ["codex", "@openai/codex", "oh-my-codex"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "grok",
            displayName: "Grok",
            assetName: nil,
            launchKinds: ["grok"],
            directBasenames: ["grok", "grok-macos-aarch64", "grok-macos-aarch"],
            argumentNeedles: ["grok", "grok-build", "@xai/grok"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "opencode",
            displayName: "OpenCode",
            assetName: "AgentIcons/OpenCode",
            launchKinds: ["opencode", "omo"],
            directBasenames: ["opencode", "opencode-ai", "open-code", "omo"],
            argumentNeedles: ["opencode", "opencode-ai", "open-code", "oh-my-openagent"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "omp",
            displayName: "OMP",
            assetName: "AgentIcons/Pi",
            launchKinds: ["omp"],
            directBasenames: ["omp"],
            argumentNeedles: ["@oh-my-pi/pi-coding-agent"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "pi",
            displayName: "Pi",
            assetName: "AgentIcons/Pi",
            launchKinds: ["pi"],
            directBasenames: ["pi", "pi-coding-agent"],
            argumentNeedles: ["@mariozechner/pi-coding-agent", "pi-coding-agent"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "amp",
            displayName: "Amp",
            assetName: nil,
            launchKinds: ["amp"],
            directBasenames: ["amp"],
            argumentNeedles: ["@ampcode"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "cursor",
            displayName: "Cursor",
            assetName: nil,
            launchKinds: ["cursor"],
            directBasenames: ["cursor-agent"],
            argumentNeedles: ["cursor-agent"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "gemini",
            displayName: "Gemini",
            assetName: nil,
            launchKinds: ["gemini"],
            directBasenames: ["gemini"],
            argumentNeedles: ["gemini"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "kiro",
            displayName: "Kiro",
            assetName: nil,
            launchKinds: ["kiro"],
            directBasenames: ["kiro", "kiro-cli"],
            argumentNeedles: ["kiro", "kiro-cli"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "antigravity",
            displayName: "Antigravity",
            assetName: "AgentIcons/Antigravity",
            launchKinds: ["antigravity", "agy"],
            directBasenames: ["agy", "antigravity"],
            argumentNeedles: ["antigravity-cli", "antigravity"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "rovodev",
            displayName: "Rovo Dev",
            assetName: "AgentIcons/RovoDev",
            launchKinds: ["rovodev", "rovo"],
            directBasenames: ["rovodev"],
            argumentNeedles: ["rovodev"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "hermes-agent",
            displayName: "Hermes Agent",
            assetName: "AgentIcons/HermesAgent",
            launchKinds: ["hermes-agent"],
            directBasenames: ["hermes", "hermes-agent"],
            argumentNeedles: ["hermes-agent"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "copilot",
            displayName: "Copilot",
            assetName: nil,
            launchKinds: ["copilot"],
            directBasenames: ["copilot"],
            argumentNeedles: ["copilot"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "codebuddy",
            displayName: "CodeBuddy",
            assetName: nil,
            launchKinds: ["codebuddy"],
            directBasenames: ["codebuddy"],
            argumentNeedles: ["codebuddy"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "factory",
            displayName: "Factory",
            assetName: nil,
            launchKinds: ["factory"],
            directBasenames: ["droid", "factory"],
            argumentNeedles: ["factory"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "qoder",
            displayName: "Qoder",
            assetName: nil,
            launchKinds: ["qoder"],
            directBasenames: ["qoder", "qodercli"],
            argumentNeedles: ["qoder", "qodercli"]
        ),
    ]

    /// Whether the detector must read a process's arguments to classify it, based on its
    /// name/path alone (host runtimes like `node`, ambiguous basenames, versioned executables).
    public static func shouldReadArguments(processName: String, processPath: String?) -> Bool {
        if let normalizedPath = normalized(processPath),
           argumentInspectionPathNeedles.contains(where: { normalizedPath.contains($0) }) {
            return true
        }

        let basenames = candidateBasenames(
            processName: processName,
            processPath: processPath,
            arguments: []
        )
        return basenames.contains { candidate in
            argumentHostBasenames.contains(candidate)
                || ambiguousDirectBasenames.contains(candidate)
                || isVersionedExecutableBasename(candidate)
        }
    }

    /// Resolves the agent definition for a running process, preferring the explicit
    /// `CMUX_AGENT_LAUNCH_KIND` environment hint, then direct basenames, then argument needles.
    public static func matchingDefinition(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        let definitions = builtIns
        let launchKind = normalized(environment["CMUX_AGENT_LAUNCH_KIND"])
        if let launchKind,
           let definition = definitions.first(where: { $0.launchKinds.contains(launchKind) }) {
            return definition
        }

        let basenames = candidateBasenames(
            processName: processName,
            processPath: processPath,
            arguments: arguments
        )
        if let definition = definitions.first(where: { definition in
            basenames.contains { definition.directBasenames.contains($0) }
        }) {
            return definition
        }

        guard !arguments.isEmpty else { return nil }
        return definitions.first { definition in
            definition.argumentNeedles.contains { needle in
                arguments.contains { argumentMatchesNeedle(argument: $0, needle: needle) }
            }
        }
    }

    private static let argumentHostBasenames: Set<String> = [
        "node", "bun", "deno", "npm", "npx", "pnpm", "yarn", "tsx"
    ]

    private static let ambiguousDirectBasenames: Set<String> = [
        "acli"
    ]

    private static let argumentInspectionPathNeedles = [
        "/.local/share/claude/versions/",
        "/library/application support/claude/claude-code/",
    ]

    private static func candidateBasenames(
        processName: String,
        processPath: String?,
        arguments: [String]
    ) -> Set<String> {
        var values = Set<String>()
        appendBasename(processName, to: &values)
        if let processPath {
            appendBasename(processPath, to: &values)
        }
        if let executable = arguments.first {
            appendBasename(executable, to: &values)
        }
        return values
    }

    private static func appendBasename(_ value: String, to values: inout Set<String>) {
        guard let normalized = normalized((value as NSString).lastPathComponent) else { return }
        values.insert(normalized)
    }

    private static func isVersionedExecutableBasename(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
        }
    }

    private static func argumentMatchesNeedle(argument: String, needle: String) -> Bool {
        guard let normalizedArgument = normalized(argument),
              let normalizedNeedle = normalized(needle) else { return false }
        if normalizedNeedle.contains("/") {
            return containsNeedleWithBoundaries(normalizedNeedle, in: normalizedArgument)
        }
        return argumentTokens(from: normalizedArgument).contains(normalizedNeedle)
    }

    private static func containsNeedleWithBoundaries(_ needle: String, in value: String) -> Bool {
        var searchRange = value.startIndex..<value.endIndex
        while let range = value.range(of: needle, range: searchRange) {
            let previous = range.lowerBound == value.startIndex ? nil : value[value.index(before: range.lowerBound)]
            let next = range.upperBound == value.endIndex ? nil : value[range.upperBound]
            let hasLeadingBoundary = needle.hasPrefix("/") || isNeedleBoundary(previous)
            let hasTrailingBoundary = needle.hasSuffix("/") || isNeedleBoundary(next)
            if hasLeadingBoundary, hasTrailingBoundary {
                return true
            }
            searchRange = range.upperBound..<value.endIndex
        }
        return false
    }

    private static func isNeedleBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.unicodeScalars.allSatisfy { scalar in
            argumentBoundaryScalars.contains(scalar)
        }
    }

    private static func argumentTokens(from value: String) -> Set<String> {
        let tokens = value
            .components(separatedBy: argumentTokenSeparators)
            .filter { !$0.isEmpty }
        return Set(tokens.flatMap { token in
            let stem = (token as NSString).deletingPathExtension
            return stem.isEmpty || stem == token ? [token] : [token, stem]
        })
    }

    private static let argumentTokenSeparators = CharacterSet(charactersIn: "/\\ \t\r\n\u{0}:=?&#\"'`<>(),;[]{}")

    private static let argumentBoundaryScalars = CharacterSet(charactersIn: "/\\ \t\r\n\u{0}:=?&#\"'`<>(),;[]{}").union(.newlines)

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
