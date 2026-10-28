import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Crash workspace merge plan")
struct CrashWorkspaceMergePlanTests {
    private func workspace(
        id: UUID? = nil, agents: Set<String> = [], title: String? = nil,
        group: UUID? = nil, dock: CrashDockSignature? = nil, score: Int = 0,
        nonAgents: Set<UUID> = [], contents: Set<String>? = []
    ) -> CrashWorkspaceSignature {
        CrashWorkspaceSignature(
            stableID: nil, workspaceID: id, checkpointIDs: agents,
            title: title, description: nil, groupID: group, directory: "/work",
            dock: dock, fidelityScore: score, nonAgentPanelIDs: nonAgents, preservedContentIDs: contents
        )
    }

    @Test("Matching identity cannot discard an incomparable agent generation")
    func incomparableAgentsSurvive() {
        let id = UUID()
        let plan = CrashWorkspaceMergePlan(
            preferred: [workspace(id: id, agents: ["shared", "old"], score: 100)],
            supplemental: [workspace(id: id, agents: ["shared", "new"]) ]
        )
        #expect(plan.selections == [.preferred(0), .supplemental(0)])
        #expect(plan.matches.isEmpty)
    }

    @Test("Agent supersets win regardless of metadata score")
    func agentSupersetWins() {
        let plan = CrashWorkspaceMergePlan(
            preferred: [workspace(agents: ["a"], score: 100)],
            supplemental: [workspace(agents: ["a", "b"])]
        )
        #expect(plan.selections == [.supplemental(0)])
        #expect(plan.matches == [0: 0])
    }

    @Test("Agent evidence cannot discard unique plain terminals or browsers")
    func uniqueNonAgentPanelsSurvive() {
        let id = UUID()
        let plan = CrashWorkspaceMergePlan(
            preferred: [workspace(id: id, agents: ["a", "b"], score: 100)],
            supplemental: [workspace(id: id, agents: ["a"], nonAgents: [UUID()])]
        )
        #expect(plan.selections == [.preferred(0), .supplemental(0)])
        #expect(plan.matches.isEmpty)
    }

    @Test("The copy covering all agent and non-agent panels wins before metadata score")
    func nonAgentSupersetWins() {
        let id = UUID(), shared = UUID(), extra = UUID()
        let plan = CrashWorkspaceMergePlan(
            preferred: [workspace(id: id, agents: ["a"], score: 100, nonAgents: [shared])],
            supplemental: [workspace(id: id, agents: ["a"], nonAgents: [shared, extra])]
        )
        #expect(plan.selections == [.supplemental(0)])
        #expect(plan.matches == [0: 0])
    }

    @Test("Recovered text wins over a metadata-rich empty copy")
    func recoveredTextSurvives() {
        let id = UUID()
        let plan = CrashWorkspaceMergePlan(
            preferred: [workspace(id: id, agents: ["a"], score: 100)],
            supplemental: [workspace(id: id, agents: ["a"], contents: ["a:scrollback"])]
        )
        #expect(plan.selections == [.supplemental(0)])
    }

    @Test("Conflicting or unknown text is never discarded", arguments: [Set(["new"]), nil])
    func conflictingTextSurvives(contents: Set<String>?) {
        let id = UUID()
        let plan = CrashWorkspaceMergePlan(
            preferred: [workspace(id: id, agents: ["a"], contents: ["old"])],
            supplemental: [workspace(id: id, agents: ["a"], contents: contents)]
        )
        #expect(plan.selections == [.preferred(0), .supplemental(0)])
    }

    @Test("An original workspace is matched at most once")
    func matchingIsOneToOne() {
        let plan = CrashWorkspaceMergePlan(
            preferred: [workspace(agents: ["a", "b"])],
            supplemental: [workspace(agents: ["a"]), workspace(agents: ["b"])]
        )
        #expect(plan.selections == [.preferred(0), .supplemental(1)])
        #expect(plan.matches == [0: 0])
    }

    @Test("Multiple checkpoint matches retain the supplemental workspace")
    func ambiguousCheckpointsStaySeparate() {
        let plan = CrashWorkspaceMergePlan(
            preferred: [workspace(agents: ["a", "b"]), workspace(agents: ["a", "c"])],
            supplemental: [workspace(agents: ["a"])]
        )
        #expect(plan.selections == [.preferred(0), .preferred(1), .supplemental(0)])
        #expect(plan.matches.isEmpty)
    }

    @Test("Identical checkpoint sets do not erase differing group membership")
    func differentGroupsStaySeparate() {
        let id = UUID()
        let plan = CrashWorkspaceMergePlan(
            preferred: [workspace(id: id, agents: ["a"])],
            supplemental: [workspace(id: id, agents: ["a"], group: UUID())]
        )
        #expect(plan.selections == [.preferred(0), .supplemental(0)])
    }

    @Test("Differing docks stay separate even when workspace identities match")
    func differentDocksStaySeparate() {
        let id = UUID()
        let dock = CrashDockSignature(panelIDs: [UUID()], checkpointIDs: ["dock"])
        let plan = CrashWorkspaceMergePlan(
            preferred: [workspace(id: id, agents: ["a"])],
            supplemental: [workspace(id: id, agents: ["a"], dock: dock)]
        )
        #expect(plan.selections == [.preferred(0), .supplemental(0)])
    }

    @Test("Reordered identity matches retain preferred order and map replaced anchors")
    func reorderedIdentityMatches() {
        let a = UUID(), b = UUID()
        let plan = CrashWorkspaceMergePlan(
            preferred: [workspace(id: a, score: 1), workspace(id: b, score: 1)],
            supplemental: [workspace(id: b, score: 2), workspace(id: a)]
        )
        #expect(plan.selections == [.preferred(0), .supplemental(0)])
        #expect(plan.matches == [0: 1, 1: 0])
    }

    @Test("A large reordered snapshot matches every stable identity once")
    func largeGenerationMatchesWithoutLoss() {
        let ids = (0..<4096).map { _ in UUID() }
        let preferred = ids.map { workspace(id: $0) }
        let supplemental = ids.reversed().map { workspace(id: $0, score: 1) }
        let plan = CrashWorkspaceMergePlan(preferred: preferred, supplemental: supplemental)
        #expect(plan.selections == ids.indices.map { .supplemental(ids.count - 1 - $0) })
        #expect(plan.matches.count == ids.count)
    }
}
