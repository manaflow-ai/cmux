import Foundation

/// The session fields a Vault exclusion rule can match.
public struct CmuxVaultSessionFields: Sendable {
    public let agentID: String
    public let agentName: String
    public let folder: String?
    public let entrypoint: String?
    public let label: String

    public init(
        agentID: String,
        agentName: String,
        folder: String?,
        entrypoint: String?,
        label: String
    ) {
        self.agentID = agentID
        self.agentName = agentName
        self.folder = folder
        self.entrypoint = entrypoint
        self.label = label
    }
}

/// A Vault rule that removes matching sessions from every Vault projection.
public struct CmuxVaultSessionExclusion: Codable, Hashable, Sendable {
    public let agent: String?
    public let folder: String?
    public let entrypoint: String?
    public let labelPattern: String?

    private enum CodingKeys: String, CodingKey {
        case agent
        case folder
        case entrypoint
        case labelPattern
        case pattern
    }

    public init(
        agent: String? = nil,
        folder: String? = nil,
        entrypoint: String? = nil,
        labelPattern: String? = nil
    ) {
        self.agent = Self.normalized(agent)
        self.folder = Self.normalized(folder)
        self.entrypoint = Self.normalized(entrypoint)
        self.labelPattern = Self.normalized(labelPattern)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = Self.normalized(try container.decodeIfPresent(String.self, forKey: .agent))
        folder = Self.normalized(try container.decodeIfPresent(String.self, forKey: .folder))
        entrypoint = Self.normalized(try container.decodeIfPresent(String.self, forKey: .entrypoint))
        let labelPattern = try container.decodeIfPresent(String.self, forKey: .labelPattern)
            ?? container.decodeIfPresent(String.self, forKey: .pattern)
        self.labelPattern = Self.normalized(labelPattern)

        guard agent != nil || folder != nil || entrypoint != nil || self.labelPattern != nil else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Vault session exclusion must specify at least one matcher"
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encodeIfPresent(folder, forKey: .folder)
        try container.encodeIfPresent(entrypoint, forKey: .entrypoint)
        try container.encodeIfPresent(labelPattern, forKey: .labelPattern)
    }

    /// Returns whether all matchers present in this rule match `session`.
    public func matches(_ session: CmuxVaultSessionFields) -> Bool {
        matches(session, compiledLabelRegex: nil, labelRegexCompiled: false)
    }

    /// Whether this rule can match a session of the given agent; a rule
    /// without an agent matcher applies to every agent.
    public func applies(toAgentID agentID: String, agentName: String) -> Bool {
        guard let pattern = agent else { return true }
        return Self.globMatches(pattern, value: agentID, caseInsensitive: true)
            || Self.globMatches(pattern, value: agentName, caseInsensitive: true)
    }

    /// `labelRegexCompiled` is true when `compiledLabelRegex` already holds the
    /// compile result, including nil for an invalid `re:` pattern, so a bad
    /// pattern is not recompiled for every session.
    fileprivate func matches(
        _ session: CmuxVaultSessionFields,
        compiledLabelRegex: NSRegularExpression?,
        labelRegexCompiled: Bool
    ) -> Bool {
        guard applies(toAgentID: session.agentID, agentName: session.agentName) else { return false }
        if let folder {
            guard let value = session.folder,
                  Self.globMatches(folder, value: value, caseInsensitive: false) else {
                return false
            }
        }
        if let entrypoint {
            guard let value = session.entrypoint,
                  Self.globMatches(entrypoint, value: value, caseInsensitive: true) else {
                return false
            }
        }
        if let labelPattern,
           !Self.labelMatches(
               labelPattern,
               value: session.label,
               compiledRegex: compiledLabelRegex,
               regexCompiled: labelRegexCompiled
           ) {
            return false
        }
        return true
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func labelMatches(
        _ pattern: String,
        value: String,
        compiledRegex: NSRegularExpression?,
        regexCompiled: Bool
    ) -> Bool {
        guard let expression = regexExpression(pattern) else {
            return globMatches(pattern, value: value, caseInsensitive: true)
        }
        let regex = regexCompiled
            ? compiledRegex
            : try? NSRegularExpression(pattern: expression, options: [.caseInsensitive])
        guard let regex else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    /// The regular expression of a `re:` label pattern, or nil for a wildcard
    /// pattern. Only the prefix opts into regex matching, so `Draft*` means
    /// "starts with Draft" rather than an unanchored `/Draft*/`.
    fileprivate static func regexExpression(_ pattern: String) -> String? {
        guard pattern.hasPrefix("re:") else { return nil }
        let expression = String(pattern.dropFirst(3))
        return expression.isEmpty ? nil : expression
    }

    /// Matches shell-style `*` and `?` wildcards in linear time.
    private static func globMatches(_ pattern: String, value: String, caseInsensitive: Bool) -> Bool {
        let patternScalars = Array((caseInsensitive ? pattern.lowercased() : pattern).unicodeScalars)
        let valueScalars = Array((caseInsensitive ? value.lowercased() : value).unicodeScalars)
        var patternIndex = 0
        var valueIndex = 0
        var starIndex: Int?
        var starValueIndex = 0

        while valueIndex < valueScalars.count {
            if patternIndex < patternScalars.count, patternScalars[patternIndex] == "*" {
                starIndex = patternIndex
                starValueIndex = valueIndex
                patternIndex += 1
            } else if patternIndex < patternScalars.count,
               patternScalars[patternIndex] == valueScalars[valueIndex] || patternScalars[patternIndex] == "?" {
                patternIndex += 1
                valueIndex += 1
            } else if let starIndex, starValueIndex < valueScalars.count {
                patternIndex = starIndex + 1
                starValueIndex += 1
                valueIndex = starValueIndex
            } else {
                return false
            }
        }

        while patternIndex < patternScalars.count, patternScalars[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternScalars.count
    }
}

/// The compiled form of one exclusion rule used while filtering a source page.
/// `NSRegularExpression` is thread-safe for matching, so this value can cross
/// the nonisolated search boundary without recompiling the rule for each entry.
public struct CmuxVaultSessionExclusionMatcher: Sendable {
    public let exclusion: CmuxVaultSessionExclusion
    private let labelRegex: NSRegularExpression?

    public init(_ exclusion: CmuxVaultSessionExclusion) {
        self.exclusion = exclusion
        if let labelPattern = exclusion.labelPattern,
           let expression = CmuxVaultSessionExclusion.regexExpression(labelPattern) {
            labelRegex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive])
        } else {
            labelRegex = nil
        }
    }

    public func matches(_ session: CmuxVaultSessionFields) -> Bool {
        exclusion.matches(session, compiledLabelRegex: labelRegex, labelRegexCompiled: true)
    }
}
