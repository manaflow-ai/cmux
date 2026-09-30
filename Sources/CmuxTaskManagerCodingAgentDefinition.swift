import CmuxTerminalCore
import Foundation

struct CmuxTaskManagerCodingAgentDefinition: Equatable, Sendable {
    let id: String
    let displayName: String
    let assetName: String?
    let launchKinds: [String]
    let directBasenames: [String]
    let argumentNeedles: [String]
    let requiredArgumentPrefix: [String]
    let promptTurnDetection: PromptLineTurnDetectionConfiguration?

    init(
        id: String,
        displayName: String,
        assetName: String?,
        launchKinds: [String],
        directBasenames: [String],
        argumentNeedles: [String],
        requiredArgumentPrefix: [String] = [],
        promptTurnDetection: PromptLineTurnDetectionConfiguration? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.assetName = assetName
        self.launchKinds = launchKinds
        self.directBasenames = directBasenames
        self.argumentNeedles = argumentNeedles
        self.requiredArgumentPrefix = requiredArgumentPrefix
        self.promptTurnDetection = promptTurnDetection
    }

    static func shouldReadArguments(processName: String, processPath: String?) -> Bool {
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

    static func matchingDefinition(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        let definitions = builtIns
        // The process's own executable identity outranks the launch-kind
        // environment: CMUX_AGENT_LAUNCH_* is inherited by every descendant
        // of the launched pane, so a later `ollama run` inside a pane that
        // launched claude still carries CMUX_AGENT_LAUNCH_KIND=claude. The
        // env var only identifies processes (wrappers, script hosts) whose
        // executable matches no agent definition of its own.
        let basenames = candidateBasenames(
            processName: processName,
            processPath: processPath,
            arguments: arguments
        )
        if let definition = definitions.first(where: { definition in
            definition.matchesRequiredArguments(arguments)
                && basenames.contains { definition.directBasenames.contains($0) }
        }) {
            return definition
        }

        let launchKind = normalized(environment["CMUX_AGENT_LAUNCH_KIND"])
        if let launchKind,
           let definition = definitions.first(where: {
               $0.launchKinds.contains(launchKind) && $0.matchesRequiredArguments(arguments)
           }) {
            return definition
        }

        guard !arguments.isEmpty else { return nil }
        return definitions.first { definition in
            definition.matchesRequiredArguments(arguments)
                && definition.argumentNeedles.contains { needle in
                    arguments.contains { argumentMatchesNeedle(argument: $0, needle: needle) }
                }
        }
    }

    private func matchesRequiredArguments(_ arguments: [String]) -> Bool {
        guard !requiredArgumentPrefix.isEmpty else { return true }
        let normalizedArguments = arguments.compactMap(Self.normalized)
        let required = requiredArgumentPrefix.compactMap(Self.normalized)
        guard normalizedArguments.count > required.count else { return false }
        return Array(normalizedArguments.dropFirst().prefix(required.count)) == required
    }

    private static let argumentHostBasenames: Set<String> = [
        "node", "bun", "deno", "npm", "npx", "pnpm", "yarn", "tsx", "ts-node"
    ]

    private static let ambiguousDirectBasenames: Set<String> = [
        "acli", "ollama"
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
