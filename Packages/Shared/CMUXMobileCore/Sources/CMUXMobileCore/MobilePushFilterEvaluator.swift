import Foundation

/// Pure matcher deciding whether a push is muted by the user's filter rules.
///
/// Mirrors the server's send-time semantics exactly so local foreground
/// filtering behaves identically before the document has synced:
/// - an enabled rule matches when ALL criteria set on it match;
/// - `macDeviceId` (if set) must equal the push's Mac id case-insensitively;
/// - the group criterion (if `groupId` or `groupName` is set) matches when
///   `groupId` equals the push's `workspaceGroupId` case-insensitively OR
///   `groupName` equals the push's `workspaceGroupName` after trimming,
///   case-insensitively;
/// - `titlePattern` (if set) is a case-insensitive `NSRegularExpression`
///   SEARCH anywhere in the push title; an invalid pattern fails the criterion
///   (fail open: it never mutes);
/// - any matching rule mutes the push.
///
/// An instantiated value (not a static namespace) per the package conventions;
/// it is stateless and free to share.
public struct MobilePushFilterEvaluator: Sendable {
    /// Creates the stateless evaluator.
    public init() {}

    /// Whether any enabled rule matches the candidate push.
    public func isMuted(
        candidate: MobilePushFilterCandidate,
        rules: [MobilePushFilterRule]
    ) -> Bool {
        rules.contains { matches(candidate: candidate, rule: $0) }
    }

    /// Whether one rule matches the candidate (AND across its set criteria).
    func matches(
        candidate: MobilePushFilterCandidate,
        rule: MobilePushFilterRule
    ) -> Bool {
        guard rule.enabled else { return false }
        let groupId = value(rule.groupId)
        let groupName = value(rule.groupName)
        let titlePattern = value(rule.titlePattern)
        // Defensive mirror of the construction-time contract: a rule with no
        // criteria must never mute everything.
        guard groupId != nil || groupName != nil || titlePattern != nil else {
            return false
        }
        guard MobilePushFilterRule.macScopeAdmits(
            value(rule.macDeviceId),
            value(candidate.macDeviceId)
        ) else { return false }
        if groupId != nil || groupName != nil {
            guard groupCriterionMatches(
                candidate: candidate,
                groupId: groupId,
                groupName: groupName
            ) else { return false }
        }
        if let titlePattern {
            guard titleCriterionMatches(
                title: candidate.title ?? "",
                pattern: titlePattern
            ) else { return false }
        }
        return true
    }

    /// `groupId` equality OR trimmed `groupName` equality, case-insensitive.
    private func groupCriterionMatches(
        candidate: MobilePushFilterCandidate,
        groupId: String?,
        groupName: String?
    ) -> Bool {
        if let groupId,
           let pushGroupId = value(candidate.workspaceGroupId),
           pushGroupId.caseInsensitiveCompare(groupId) == .orderedSame {
            return true
        }
        if let groupName,
           let pushGroupName = value(candidate.workspaceGroupName) {
            let ruleName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            let pushName = pushGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ruleName.isEmpty,
               pushName.caseInsensitiveCompare(ruleName) == .orderedSame {
                return true
            }
        }
        return false
    }

    /// Case-insensitive regex search; an uncompilable pattern fails open.
    private func titleCriterionMatches(title: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.firstMatch(in: title, options: [], range: range) != nil
    }

    /// Treats absent or whitespace-only strings as unset criteria.
    private func value(_ string: String?) -> String? {
        guard let string,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return string
    }
}
