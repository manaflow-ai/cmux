import Foundation

/// Classifies an agent from free-form name candidates (process names, titles,
/// labels) by case-insensitive substring match and returns the matched agent's
/// brand-mark asset catalog image name.
///
/// This is the pure name->asset classifier extracted from `SessionAgent`. The
/// task-manager snapshot parser holds it as a value-typed seam
/// (`SessionAgentAssetResolver.standard`) instead of reaching into `SessionAgent`
/// statics, so the classification table is an injectable value and the parser
/// depends on a plain value rather than the agent enum's presentation surface.
/// `SessionAgent` itself stays app-side (its `.registered` case is coupled to
/// `CmuxVaultAgentRegistration`); only this pure classifier is split out.
struct SessionAgentAssetResolver: Sendable {
    /// One classification rule: a lowercased substring `token` and the
    /// `assetName` returned when a candidate contains it.
    struct Rule: Sendable {
        let token: String
        let assetName: String?
    }

    /// Ordered classification rules. Candidates are tested against each rule in
    /// order; the first rule whose `token` is contained in the candidate wins.
    let rules: [Rule]

    /// The production classifier. Token order and asset names mirror the agents'
    /// brand marks exactly (opencode, hermes, claude, codex), sourcing each asset
    /// name from the owning `SessionAgent` case so there is a single source of
    /// truth for the brand-mark image names.
    static let standard = SessionAgentAssetResolver(rules: [
        Rule(token: "opencode", assetName: SessionAgent.opencode.assetName),
        Rule(token: "hermes", assetName: SessionAgent.hermesAgent.assetName),
        Rule(token: "claude", assetName: SessionAgent.claude.assetName),
        Rule(token: "codex", assetName: SessionAgent.codex.assetName)
    ])

    /// Returns the brand-mark asset name for the first candidate whose lowercased
    /// text contains a known agent token, trying candidates in order. Returns
    /// `nil` when no candidate matches.
    func assetName(forNameCandidates candidates: [String?]) -> String? {
        for candidate in candidates.compactMap({ $0?.lowercased() }) {
            for rule in rules where candidate.contains(rule.token) {
                return rule.assetName
            }
        }
        return nil
    }
}
