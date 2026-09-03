import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct MobilePushFilterEvaluatorTests {
    private let evaluator = MobilePushFilterEvaluator()

    private func rule(
        enabled: Bool = true,
        groupId: String? = nil,
        groupName: String? = nil,
        macDeviceId: String? = nil,
        titlePattern: String? = nil
    ) throws -> MobilePushFilterRule {
        try #require(MobilePushFilterRule.validated(
            enabled: enabled,
            groupId: groupId,
            groupName: groupName,
            macDeviceId: macDeviceId,
            titlePattern: titlePattern
        ))
    }

    @Test func groupIdMatchesCaseInsensitively() throws {
        let rules = [try rule(groupId: "Group-1")]
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(workspaceGroupId: "group-1"),
            rules: rules
        ))
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(workspaceGroupId: "group-2"),
            rules: rules
        ))
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(title: "anything"),
            rules: rules
        ))
    }

    @Test func groupNameMatchesTrimmedCaseInsensitively() throws {
        let rules = [try rule(groupName: "  Backend Agents ")]
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(workspaceGroupName: "backend agents"),
            rules: rules
        ))
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(workspaceGroupName: "BACKEND AGENTS\n"),
            rules: rules
        ))
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(workspaceGroupName: "frontend agents"),
            rules: rules
        ))
    }

    @Test func groupCriterionIsIdOrName() throws {
        let rules = [try rule(groupId: "group-1", groupName: "Backend")]
        // Different id, matching name: still the same group criterion.
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(
                workspaceGroupId: "group-9",
                workspaceGroupName: "backend"
            ),
            rules: rules
        ))
        // Matching id, different name.
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(
                workspaceGroupId: "GROUP-1",
                workspaceGroupName: "renamed"
            ),
            rules: rules
        ))
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(
                workspaceGroupId: "group-9",
                workspaceGroupName: "renamed"
            ),
            rules: rules
        ))
    }

    @Test func macDeviceIdScopesTheRule() throws {
        let rules = [try rule(groupId: "group-1", macDeviceId: "MAC-1")]
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(
                workspaceGroupId: "group-1",
                macDeviceId: "mac-1"
            ),
            rules: rules
        ))
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(
                workspaceGroupId: "group-1",
                macDeviceId: "mac-2"
            ),
            rules: rules
        ))
        // A push without a Mac id cannot satisfy a Mac-scoped rule.
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(workspaceGroupId: "group-1"),
            rules: rules
        ))
    }

    @Test func titlePatternSearchesCaseInsensitively() throws {
        let rules = [try rule(titlePattern: "fail(ed|ure)")]
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(title: "Build FAILED on main"),
            rules: rules
        ))
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(title: "infra failure detected"),
            rules: rules
        ))
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(title: "Build passed"),
            rules: rules
        ))
        // A nil title matches like an empty string.
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(),
            rules: rules
        ))
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(),
            rules: [try rule(titlePattern: "^$")]
        ))
    }

    @Test func criteriaCombineWithAND() throws {
        let rules = [try rule(groupId: "group-1", titlePattern: "fail")]
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(
                title: "agent failed",
                workspaceGroupId: "group-1"
            ),
            rules: rules
        ))
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(
                title: "agent finished",
                workspaceGroupId: "group-1"
            ),
            rules: rules
        ))
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(
                title: "agent failed",
                workspaceGroupId: "group-2"
            ),
            rules: rules
        ))
    }

    @Test func invalidPatternFailsOpen() throws {
        let rules = [try rule(titlePattern: "([")]
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(title: "(["),
            rules: rules
        ))
    }

    @Test func disabledRuleNeverMutes() throws {
        let rules = [try rule(enabled: false, groupId: "group-1")]
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(workspaceGroupId: "group-1"),
            rules: rules
        ))
    }

    @Test func anyMatchingRuleMutes() throws {
        let rules = [
            try rule(groupId: "group-1"),
            try rule(titlePattern: "deploy"),
        ]
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(title: "Deploy finished"),
            rules: rules
        ))
        #expect(evaluator.isMuted(
            candidate: MobilePushFilterCandidate(workspaceGroupId: "group-1"),
            rules: rules
        ))
        #expect(!evaluator.isMuted(
            candidate: MobilePushFilterCandidate(title: "tests green"),
            rules: rules
        ))
    }
}
