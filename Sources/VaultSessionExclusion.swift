import Foundation

/// A Vault rule that removes matching sessions from every Vault projection.
struct CmuxVaultSessionExclusion: Codable, Hashable, Sendable {
    let agent: String?
    let folder: String?
    let entrypoint: String?
    let labelPattern: String?

    private enum CodingKeys: String, CodingKey {
        case agent
        case folder
        case entrypoint
        case labelPattern
        case pattern
    }

    init(
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encodeIfPresent(folder, forKey: .folder)
        try container.encodeIfPresent(entrypoint, forKey: .entrypoint)
        try container.encodeIfPresent(labelPattern, forKey: .labelPattern)
    }

    /// Returns whether all matchers present in this rule match `entry`.
    func matches(_ entry: SessionEntry) -> Bool {
        matches(entry, compiledLabelRegex: nil)
    }

    fileprivate func matches(
        _ entry: SessionEntry,
        compiledLabelRegex: NSRegularExpression?
    ) -> Bool {
        if let agent {
            let matchesID = Self.globMatches(agent, value: entry.agent.rawValue, caseInsensitive: true)
            let matchesName = Self.globMatches(agent, value: entry.agent.displayName, caseInsensitive: true)
            guard matchesID || matchesName else { return false }
        }
        if let folder {
            guard let cwd = entry.cwd,
                  Self.globMatches(folder, value: cwd, caseInsensitive: false) else {
                return false
            }
        }
        if let entrypoint {
            guard let value = entry.entrypoint,
                  Self.globMatches(entrypoint, value: value, caseInsensitive: true) else {
                return false
            }
        }
        if let labelPattern,
           !Self.labelMatches(labelPattern, value: entry.title, compiledRegex: compiledLabelRegex) {
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
        compiledRegex: NSRegularExpression?
    ) -> Bool {
        guard let expression = regexExpression(pattern) else {
            return globMatches(pattern, value: value, caseInsensitive: true)
        }
        let regex = compiledRegex ?? (try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]))
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

    /// Whether this rule can match a session of `agent`; a rule without an
    /// agent matcher applies to every agent.
    func applies(to agent: SessionAgent) -> Bool {
        guard let pattern = self.agent else { return true }
        return Self.globMatches(pattern, value: agent.rawValue, caseInsensitive: true)
            || Self.globMatches(pattern, value: agent.displayName, caseInsensitive: true)
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
struct CmuxVaultSessionExclusionMatcher: Sendable {
    let exclusion: CmuxVaultSessionExclusion
    private let labelRegex: NSRegularExpression?

    init(_ exclusion: CmuxVaultSessionExclusion) {
        self.exclusion = exclusion
        if let labelPattern = exclusion.labelPattern,
           let expression = CmuxVaultSessionExclusion.regexExpression(labelPattern) {
            labelRegex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive])
        } else {
            labelRegex = nil
        }
    }

    func matches(_ entry: SessionEntry) -> Bool {
        exclusion.matches(entry, compiledLabelRegex: labelRegex)
    }
}
