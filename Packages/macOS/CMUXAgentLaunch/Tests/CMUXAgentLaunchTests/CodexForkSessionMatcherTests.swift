import Foundation
import Testing

@testable import CMUXAgentLaunch

@Suite
struct CodexForkSessionMatcherTests {
    @Test
    func siblingForksUseTheRolloutHeldByTheirOwnProcess() {
        let parent = "parent"
        let launchedAt = Date(timeIntervalSince1970: 100)
        let first = CodexForkSessionCandidate(
            sessionID: "child-a",
            parentSessionID: parent,
            transcriptPath: "/sessions/child-a.jsonl",
            createdAt: Date(timeIntervalSince1970: 101)
        )
        let second = CodexForkSessionCandidate(
            sessionID: "child-b",
            parentSessionID: parent,
            transcriptPath: "/sessions/child-b.jsonl",
            createdAt: Date(timeIntervalSince1970: 102)
        )
        let matcher = CodexForkSessionMatcher()

        #expect(
            matcher.match(
                parentSessionID: parent,
                launchedAt: launchedAt,
                candidates: [first, second],
                ownerRolloutPaths: [first.transcriptPath]
            ) == first
        )
        #expect(
            matcher.match(
                parentSessionID: parent,
                launchedAt: launchedAt,
                candidates: [first, second],
                ownerRolloutPaths: [second.transcriptPath]
            ) == second
        )
    }

    @Test
    func missingOwnerEvidenceFailsClosed() {
        let candidate = CodexForkSessionCandidate(
            sessionID: "child",
            parentSessionID: "parent",
            transcriptPath: "/sessions/child.jsonl",
            createdAt: Date(timeIntervalSince1970: 101)
        )
        #expect(
            CodexForkSessionMatcher().match(
                parentSessionID: "parent",
                launchedAt: Date(timeIntervalSince1970: 100),
                candidates: [candidate],
                ownerRolloutPaths: []
            ) == nil
        )
    }

    @Test
    func multipleOwnedChildrenFailClosed() {
        let candidate = CodexForkSessionCandidate(
            sessionID: "child-a",
            parentSessionID: "parent",
            transcriptPath: "/sessions/child-a.jsonl",
            createdAt: Date(timeIntervalSince1970: 101)
        )
        let sibling = CodexForkSessionCandidate(
            sessionID: "child-b",
            parentSessionID: "parent",
            transcriptPath: "/sessions/child-b.jsonl",
            createdAt: Date(timeIntervalSince1970: 102)
        )
        #expect(
            CodexForkSessionMatcher().match(
                parentSessionID: "parent",
                launchedAt: Date(timeIntervalSince1970: 100),
                candidates: [candidate, sibling],
                ownerRolloutPaths: [candidate.transcriptPath, sibling.transcriptPath]
            ) == nil
        )
    }

    @Test
    func ownerEvidenceAllowsSlowForkStartup() {
        let candidate = CodexForkSessionCandidate(
            sessionID: "child",
            parentSessionID: "parent",
            transcriptPath: "/sessions/child.jsonl",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        #expect(
            CodexForkSessionMatcher().match(
                parentSessionID: "parent",
                launchedAt: Date(timeIntervalSince1970: 100),
                candidates: [candidate],
                ownerRolloutPaths: [candidate.transcriptPath]
            ) == candidate
        )
    }
}
