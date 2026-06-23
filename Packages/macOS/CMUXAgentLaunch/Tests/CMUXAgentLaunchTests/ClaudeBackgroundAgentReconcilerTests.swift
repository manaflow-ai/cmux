import CMUXAgentLaunch
import Foundation
import Testing

@Suite("ClaudeBackgroundAgentReconciler")
struct ClaudeBackgroundAgentReconcilerTests {
    private let reconciler = ClaudeBackgroundAgentReconciler()

    // The core #6622 fix: a transcript-less ghost panel reconciles to the unique live
    // background agent for its cwd, so resume targets the real conversation id.
    @Test("Unique background agent in the cwd reconciles the ghost")
    func uniqueBackgroundAgentReconciles() {
        let agents = [
            ClaudeBackgroundAgentSnapshot(sessionId: "real-id", cwd: "/Users/me/repo", kind: "background"),
        ]
        #expect(
            reconciler.reconciledSessionId(
                forGhostSessionId: "ghost-id",
                panelCwd: "/Users/me/repo",
                backgroundAgents: agents
            ) == "real-id"
        )
    }

    @Test("Trailing-slash / dot path segments still match the agent cwd")
    func cwdIsPathNormalized() {
        let agents = [
            ClaudeBackgroundAgentSnapshot(sessionId: "real-id", cwd: "/Users/me/repo", kind: "background"),
        ]
        #expect(
            reconciler.reconciledSessionId(
                forGhostSessionId: "ghost-id",
                panelCwd: "/Users/me/./repo/",
                backgroundAgents: agents
            ) == "real-id"
        )
    }

    @Test("No background agent for the cwd leaves the panel unchanged")
    func noMatchReturnsNil() {
        let agents = [
            ClaudeBackgroundAgentSnapshot(sessionId: "real-id", cwd: "/Users/me/other", kind: "background"),
        ]
        #expect(
            reconciler.reconciledSessionId(
                forGhostSessionId: "ghost-id",
                panelCwd: "/Users/me/repo",
                backgroundAgents: agents
            ) == nil
        )
    }

    @Test("Several background agents in the same cwd are ambiguous and reconcile to nothing")
    func ambiguousCwdReturnsNil() {
        let agents = [
            ClaudeBackgroundAgentSnapshot(sessionId: "a", cwd: "/Users/me/repo", kind: "background"),
            ClaudeBackgroundAgentSnapshot(sessionId: "b", cwd: "/Users/me/repo", kind: "background"),
        ]
        #expect(
            reconciler.reconciledSessionId(
                forGhostSessionId: "ghost-id",
                panelCwd: "/Users/me/repo",
                backgroundAgents: agents
            ) == nil
        )
    }

    @Test("Interactive (non-background) sessions are never reconciliation targets")
    func interactiveKindIsIgnored() {
        let agents = [
            ClaudeBackgroundAgentSnapshot(sessionId: "real-id", cwd: "/Users/me/repo", kind: "interactive"),
        ]
        #expect(
            reconciler.reconciledSessionId(
                forGhostSessionId: "ghost-id",
                panelCwd: "/Users/me/repo",
                backgroundAgents: agents
            ) == nil
        )
    }

    @Test("An agent whose id equals the ghost id is not a reconciliation target")
    func ghostIdIsNotItsOwnTarget() {
        let agents = [
            ClaudeBackgroundAgentSnapshot(sessionId: "ghost-id", cwd: "/Users/me/repo", kind: "background"),
        ]
        #expect(
            reconciler.reconciledSessionId(
                forGhostSessionId: "ghost-id",
                panelCwd: "/Users/me/repo",
                backgroundAgents: agents
            ) == nil
        )
    }

    @Test("A panel without a cwd cannot be reconciled")
    func missingPanelCwdReturnsNil() {
        let agents = [
            ClaudeBackgroundAgentSnapshot(sessionId: "real-id", cwd: "/Users/me/repo", kind: "background"),
        ]
        #expect(
            reconciler.reconciledSessionId(
                forGhostSessionId: "ghost-id",
                panelCwd: nil,
                backgroundAgents: agents
            ) == nil
        )
    }

    // The daemon prints the full conversation id under `sessionId`; the short `id` is only a
    // fallback. `claude --resume` needs the full id, so prefer `sessionId`.
    @Test("parse prefers the full sessionId over the short id")
    func parsePrefersSessionId() throws {
        let json = Data("""
        [{"id":"7c5dcf5d","sessionId":"bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb","cwd":"/Users/me/repo","kind":"background","state":"blocked","status":"idle"}]
        """.utf8)
        let agents = ClaudeBackgroundAgentReconciler.parse(agentsJSON: json)
        #expect(agents.count == 1)
        #expect(agents.first?.sessionId == "bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb")
        #expect(agents.first?.cwd == "/Users/me/repo")
        #expect(agents.first?.kind == "background")
    }

    @Test("parse falls back to the short id when sessionId is absent")
    func parseFallsBackToId() {
        let json = Data(#"[{"id":"7c5dcf5d","cwd":"/Users/me/repo","kind":"background"}]"#.utf8)
        let agents = ClaudeBackgroundAgentReconciler.parse(agentsJSON: json)
        #expect(agents.first?.sessionId == "7c5dcf5d")
    }

    @Test("parse tolerates malformed output")
    func parseToleratesGarbage() {
        #expect(ClaudeBackgroundAgentReconciler.parse(agentsJSON: Data("not json".utf8)).isEmpty)
        #expect(ClaudeBackgroundAgentReconciler.parse(agentsJSON: Data("{}".utf8)).isEmpty)
        #expect(ClaudeBackgroundAgentReconciler.parse(agentsJSON: Data("[]".utf8)).isEmpty)
    }

    @Test("parse with daemon output reconciles end-to-end")
    func parseThenReconcile() {
        let json = Data("""
        [{"sessionId":"real-id","cwd":"/Users/me/repo","kind":"background","state":"blocked"}]
        """.utf8)
        let agents = ClaudeBackgroundAgentReconciler.parse(agentsJSON: json)
        #expect(
            reconciler.reconciledSessionId(
                forGhostSessionId: "ghost-id",
                panelCwd: "/Users/me/repo",
                backgroundAgents: agents
            ) == "real-id"
        )
    }
}
