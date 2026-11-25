import Foundation

/// The decision proof of a relayed answer to a question (acpmux `decision_answers_proof`,
/// `hub/person/decision_answers.rs`): an AskUserQuestion answered in this pane for a chat on
/// another machine. The allow's proof also covers the answers, and the annotations (Claude Code's
/// chosen preview and notes) when there are any, so that machine's daemon counts the answer as the
/// person's and a relay can neither swap nor add them. Without it every such answer was
/// refused as "accepted only from the cmux app" (Leo, 2026-10-21).
nonisolated extension AcpmuxSecretKey {
    /// `personDecision` of a relayed answer; nil when the answers or annotations have no canonical
    /// form (a fractional number, which no question answer has). The annotations' digest is a
    /// seventh part only when there are annotations, as acpmux reads it.
    public func decisionProof(instance: String, session: String, permission: String, option: String, nonce: String,
                              answers: Any, annotations: Any? = nil) -> String? {
        guard let answersDigest = Self.canonicalDigest(answers) else { return nil }
        var parts = [instance, session, permission, option, nonce, answersDigest]
        if let annotations, !(annotations is NSNull) {
            guard let notesDigest = Self.canonicalDigest(annotations) else { return nil }
            parts.append(notesDigest)
        }
        return mac(domain: "acpmux-person-decision-answers-v1", parts: parts)
    }

    /// The lowercase hex sha256 of `value`'s canonical JSON bytes (acpmux
    /// `approvers::answers_digest`), from the Rust policy (cmux-agent-pane-policy `canonical_digest`).
    /// Hex, so comparing two is comparing those bytes: `String` equality treats canonically
    /// equivalent Unicode (a composed and a decomposed é) as equal.
    static func canonicalDigest(_ value: Any) -> String? {
        AgentPanePolicyFFI.call("canonical_digest", ["value": value])?["digest"] as? String
    }

    /// The bytes acpmux hashes (`approvers::canonical_json`), from the Rust policy
    /// (cmux-agent-pane-policy `canonical_json`): object keys in UTF-8 byte order, no whitespace,
    /// and only `"`, `\` and control characters escaped. nil for a value with no canonical form (a
    /// fractional number). `value` is what `JSONSerialization` parsed.
    static func canonicalJSON(_ value: Any) -> String? {
        AgentPanePolicyFFI.call("canonical_json", ["value": value])?["json"] as? String
    }
}
