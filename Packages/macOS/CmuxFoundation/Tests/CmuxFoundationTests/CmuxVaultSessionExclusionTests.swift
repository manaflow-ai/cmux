import Foundation
import Testing
@testable import CmuxFoundation

/// Covers ``CmuxVaultSessionExclusion``: rule decoding and the wildcard and
/// `re:` label matching Vault uses to hide sessions.
@Suite("Vault session exclusion rules")
struct CmuxVaultSessionExclusionTests {
    @Test("A label pattern without re: is a wildcard, not a substring regex")
    func labelPatternIsWildcardUnlessPrefixed() {
        let wildcard = CmuxVaultSessionExclusion(labelPattern: "Draft*")
        let regex = CmuxVaultSessionExclusion(labelPattern: "re:draft")

        #expect(wildcard.matches(session(label: "Draft notes")))
        #expect(!wildcard.matches(session(label: "Redrafting notes")))
        #expect(regex.matches(session(label: "Redrafting notes")))
    }

    @Test("A wildcard still spans a literal star in the label")
    func wildcardSpansLiteralStar() {
        let rule = CmuxVaultSessionExclusion(labelPattern: "*review*")

        #expect(rule.matches(session(label: "**Bold** review this")))
    }

    @Test("A compiled matcher agrees with the rule, including an invalid re: pattern")
    func compiledMatcherAgreesWithRule() {
        let valid = CmuxVaultSessionExclusion(labelPattern: "re:^Review this")
        let invalid = CmuxVaultSessionExclusion(labelPattern: "re:(")

        #expect(CmuxVaultSessionExclusionMatcher(valid).matches(session(label: "Review this change")))
        #expect(!CmuxVaultSessionExclusionMatcher(valid).matches(session(label: "Please Review this")))
        #expect(!CmuxVaultSessionExclusionMatcher(invalid).matches(session(label: "(")))
        #expect(!invalid.matches(session(label: "(")))
    }

    @Test("Agent rules match the agent id or display name")
    func agentRuleMatchesIDOrName() {
        let rule = CmuxVaultSessionExclusion(agent: "claude*")

        #expect(rule.applies(toAgentID: "claude", agentName: "Claude Code"))
        #expect(rule.applies(toAgentID: "cc", agentName: "Claude Code"))
        #expect(!rule.applies(toAgentID: "codex", agentName: "Codex"))
        #expect(CmuxVaultSessionExclusion(folder: "/tmp/*").applies(toAgentID: "codex", agentName: "Codex"))
    }

    @Test("Pattern is accepted as a label matcher alias, and an empty rule is rejected")
    func patternAliasDecodes() throws {
        let rule = try JSONDecoder().decode(
            CmuxVaultSessionExclusion.self,
            from: Data(#"{"pattern":"*background*"}"#.utf8)
        )

        #expect(rule.labelPattern == "*background*")
        #expect(rule.matches(session(label: "background review")))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CmuxVaultSessionExclusion.self, from: Data(#"{"agent":"  "}"#.utf8))
        }
    }

    private func session(
        agentID: String = "claude",
        agentName: String = "Claude Code",
        folder: String? = "/work",
        entrypoint: String? = nil,
        label: String
    ) -> CmuxVaultSessionFields {
        CmuxVaultSessionFields(
            agentID: agentID,
            agentName: agentName,
            folder: folder,
            entrypoint: entrypoint,
            label: label
        )
    }
}
