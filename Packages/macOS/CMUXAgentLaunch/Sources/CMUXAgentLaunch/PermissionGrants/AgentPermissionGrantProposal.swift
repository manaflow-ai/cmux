public import Foundation

/// A validated request for a batch grant, before the user has answered it.
///
/// Agents send these through the `permissions.request` socket method. The
/// request is untrusted text: the app shows the rules it parsed here and
/// quotes the reason, and nothing is granted until the user approves.
public struct AgentPermissionGrantProposal: Sendable, Equatable {
    /// The most rules one request may carry.
    public static let maximumRuleCount = 32
    /// The longest rule accepted, in characters.
    public static let maximumRuleLength = 512
    /// The longest reason kept, in characters. Longer reasons are cut.
    public static let maximumReasonLength = 500

    /// One requested rule and whether it is broad enough to need care.
    public struct Rule: Sendable, Equatable, Identifiable {
        public var rule: String
        /// Broad rules start unchecked in the approval UI.
        public var isBroad: Bool
        public var id: String { rule }
    }

    public var rules: [Rule]
    public var scope: AgentPermissionGrant.Scope
    public var reason: String?
    public var expiresIn: TimeInterval

    /// Why a `permissions.request` payload was rejected.
    public enum ValidationError: Error, Sendable, Equatable {
        case missingRules
        case tooManyRules
        case invalidRule(String)
        case invalidScope
        case missingSessionID
        case invalidProjectRoot
        case invalidExpiry
    }

    /// Validates socket parameters:
    /// `{rules: [String], scope: "session"|"project", session_id?, root?,
    /// reason?, expires_in_seconds?}`.
    ///
    /// Rules are trimmed and de-duplicated in order. A session scope needs a
    /// `session_id`; a project scope needs an absolute `root` naming an
    /// existing directory other than `/`, which is stored canonicalized.
    public static func parse(params: [String: Any]) -> Result<Self, ValidationError> {
        guard let rawRules = params["rules"] as? [Any], !rawRules.isEmpty else {
            return .failure(.missingRules)
        }
        var rules: [Rule] = []
        for raw in rawRules {
            guard let text = raw as? String else { return .failure(.invalidRule(String(describing: raw))) }
            let rule = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.isEmpty, rule.count <= maximumRuleLength,
                  !rule.contains(where: { $0.isNewline }),
                  AgentPermissionRuleMatcher.parse(rule) != nil else {
                return .failure(.invalidRule(text))
            }
            if !rules.contains(where: { $0.rule == rule }) {
                rules.append(Rule(rule: rule, isBroad: AgentPermissionRuleMatcher.isBroad(rule)))
            }
        }
        guard rules.count <= maximumRuleCount else { return .failure(.tooManyRules) }

        let scope: AgentPermissionGrant.Scope
        switch (params["scope"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "session":
            guard let id = (params["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else {
                return .failure(.missingSessionID)
            }
            scope = .session(id: id)
        case "project":
            guard let raw = params["root"] as? String, raw.hasPrefix("/"),
                  let root = AgentPermissionPath.canonical(raw), root != "/" else {
                return .failure(.invalidProjectRoot)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .failure(.invalidProjectRoot)
            }
            scope = .project(root: root)
        default:
            return .failure(.invalidScope)
        }

        var expiresIn = AgentPermissionGrantDuration.defaultSeconds
        if let raw = params["expires_in_seconds"] {
            guard let seconds = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init),
                  seconds.isFinite,
                  seconds >= AgentPermissionGrantDuration.minimumSeconds,
                  seconds <= AgentPermissionGrantDuration.maximumSeconds else {
                return .failure(.invalidExpiry)
            }
            expiresIn = seconds.rounded()
        }

        let reason = (params["reason"] as? String)
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumReasonLength)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return .success(Self(rules: rules, scope: scope, reason: reason, expiresIn: expiresIn))
    }

    /// The rules the approval UI checks before the user changes anything:
    /// every rule that isn't broad.
    public var defaultSelection: Set<String> {
        Set(rules.filter { !$0.isBroad }.map(\.rule))
    }

    /// The grant that approving `selected` creates, keeping request order.
    /// - Returns: `nil` when none of the selected rules were requested.
    public func grant(approving selected: Set<String>, now: Date = Date()) -> AgentPermissionGrant? {
        let approved = rules.map(\.rule).filter { selected.contains($0) }
        guard !approved.isEmpty else { return nil }
        return AgentPermissionGrant(
            rules: approved,
            scope: scope,
            reason: reason,
            grantedAt: now,
            expiresAt: now.addingTimeInterval(expiresIn)
        )
    }
}
