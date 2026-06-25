import Foundation

/// Recognizes which coding agent (if any) a running process is, by matching its name, executable
/// path, argument vector, and launch-kind environment against a catalog of ``AgentDefinition``s.
///
/// The catalog is injected at construction so the detector is a real instance you hold and reuse,
/// not a static utility. The composition root passes ``AgentDefinition/builtIns`` (the default), and
/// tests can pass a narrowed catalog. Matching precedence, faithfully preserved: an explicit
/// `CMUX_AGENT_LAUNCH_KIND` wins, then a direct executable basename, then an argument-needle match.
public struct AgentDetector: Sendable {
    /// The agent catalog this detector matches against, in priority order.
    public let catalog: [AgentDefinition]

    /// Creates a detector over the given catalog, defaulting to the built-in agent catalog.
    public init(catalog: [AgentDefinition] = AgentDefinition.builtIns) {
        self.catalog = catalog
    }

    /// Whether the agent's full argument vector must be read to classify this process.
    ///
    /// True when the executable path sits under a known versioned install location, or when the
    /// process basename is a host interpreter / ambiguous launcher / versioned executable whose
    /// identity can only be resolved from its arguments.
    public func shouldReadArguments(processName: String, processPath: String?) -> Bool {
        if let normalizedPath = Self.normalized(processPath),
           Self.argumentInspectionPathNeedles.contains(where: { normalizedPath.contains($0) }) {
            return true
        }

        let basenames = Self.candidateBasenames(
            processName: processName,
            processPath: processPath,
            arguments: []
        )
        return basenames.contains { candidate in
            Self.argumentHostBasenames.contains(candidate)
                || Self.ambiguousDirectBasenames.contains(candidate)
                || Self.isVersionedExecutableBasename(candidate)
        }
    }

    /// The matching agent definition for a process, or `nil` if none in the catalog matches.
    public func match(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> AgentDefinition? {
        let definitions = catalog
        let launchKind = Self.normalized(environment["CMUX_AGENT_LAUNCH_KIND"])
        if let launchKind,
           let definition = definitions.first(where: { $0.launchKinds.contains(launchKind) }) {
            return definition
        }

        let basenames = Self.candidateBasenames(
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
                arguments.contains { Self.argumentMatchesNeedle(argument: $0, needle: needle) }
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
