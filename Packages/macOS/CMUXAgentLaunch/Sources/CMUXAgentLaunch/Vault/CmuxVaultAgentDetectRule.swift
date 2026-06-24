public import Foundation

/// Rule that decides whether a detected running process is an instance of a
/// Vault agent registration.
///
/// A process matches when its executable basename is one of the expected names
/// (`processName` plus `processNames`) and its argv contains every needle in
/// `argvContains`, OR when its argv contains every needle in
/// `alternateArgvContains` (a second, name-independent path). All input strings
/// are trimmed and blanks dropped on construction and decode. The custom Codable
/// spelling accepts either a single string or an array for each name/argv field,
/// so config stays byte-compatible.
public struct CmuxVaultAgentDetectRule: Codable, Hashable, Sendable {
    /// A single expected executable basename, if configured.
    public var processName: String?
    /// Additional expected executable basenames.
    public var processNames: [String]
    /// Argv needles that must all be present alongside a name match.
    public var argvContains: [String]
    /// Argv needles that, when all present, match regardless of executable name.
    public var alternateArgvContains: [String]

    private enum CodingKeys: String, CodingKey {
        case processName, processNames, argvContains, alternateArgvContains
    }

    /// Creates a detect rule, trimming each string and dropping blanks.
    public init(
        processName: String? = nil,
        processNames: [String] = [],
        argvContains: [String] = [],
        alternateArgvContains: [String] = []
    ) {
        let name = processName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.processName = name?.isEmpty == true ? nil : name
        self.processNames = processNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.argvContains = argvContains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.alternateArgvContains = alternateArgvContains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Decodes a rule, accepting either a single string or an array for each
    /// name/argv field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .processName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        processName = name?.isEmpty == true ? nil : name
        processNames = try Self.decodeOneOrManyStrings(forKey: .processNames, in: container)
        argvContains = try Self.decodeOneOrManyStrings(forKey: .argvContains, in: container)
        alternateArgvContains = try Self.decodeOneOrManyStrings(forKey: .alternateArgvContains, in: container)
    }

    private static func decodeOneOrManyStrings(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String] {
        if let values = try? container.decode([String].self, forKey: key) {
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let value = try container.decodeIfPresent(String.self, forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return [value]
        }
        return []
    }
}

extension CmuxVaultAgentDetectRule {
    /// Returns whether the given observed process satisfies this rule.
    ///
    /// A rule with no names and no argv needles never matches. Otherwise the
    /// process matches when every expected basename path is satisfied (an empty
    /// name set is treated as satisfied) and every `argvContains` needle is
    /// present, OR when `alternateArgvContains` is non-empty and all its needles
    /// are present.
    public func matches(_ process: VaultObservedAgentProcess) -> Bool {
        var expectedNames = processNames
        if let processName {
            expectedNames.append(processName)
        }
        guard !expectedNames.isEmpty || !argvContains.isEmpty || !alternateArgvContains.isEmpty else {
            return false
        }
        let processNameMatch = expectedNames.isEmpty || expectedNames.contains { expected in
            process.executableBasenames.contains { candidate in
                candidate.compare(expected, options: [.caseInsensitive, .literal]) == .orderedSame
            }
        }
        let argvContainsMatch = argvContains.isEmpty || process.argumentsContainAll(argvContains)
        let alternateArgvContainsMatch = !alternateArgvContains.isEmpty
            && process.argumentsContainAll(alternateArgvContains)
        return (processNameMatch && argvContainsMatch) || alternateArgvContainsMatch
    }
}
