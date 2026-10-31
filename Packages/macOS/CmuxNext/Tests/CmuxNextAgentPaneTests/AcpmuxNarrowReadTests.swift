@testable import CmuxNextAgentPane
import Foundation
import Testing

@Suite struct AcpmuxNarrowReadTests {
    @Test func aSessionInfoRowBuildsTheDeepLinkSubject() {
        let found = AcpmuxSessionPage.chat("closed-1", in: [
            "sessionId": "closed-1", "name": "huge-blue/fix", "title": "Fix", "harness": "codex", "peer": "huge-blue",
        ])
        #expect(found?.chat == AcpmuxSessionPage.Chat(id: "closed-1", title: "Fix", harness: "codex"))
        #expect(found?.peer == "huge-blue")
    }

    @Test func resolveKeepsAnOfflinePeerRowNarrowAndExact() {
        let result: [String: Any] = ["session": [
            "sessionId": "closed-1", "name": "gcp/closed", "title": "Closed", "peer": "gcp",
        ]]
        let summary = AcpmuxStatusClient.sessionSummary("closed-1", in: result)
        #expect(summary?["peer"] as? String == "gcp")
        #expect(AcpmuxStatusClient.sessionSummary("other", in: result) == nil)
    }

    @Test func legacyResolverUsesAnExactMatchWhenPrimaryMatchDiffers() {
        let result: [String: Any] = [
            "session": ["sessionId": "newer-name-match"],
            "matches": [["sessionId": "target"]],
        ]
        #expect(AcpmuxStatusClient.sessionSummary("target", in: result)?["sessionId"] as? String == "target")
    }

    @Test func exactResolveFallsBackForOlderDaemons() {
        #expect(AcpmuxStatusClient.shouldFallbackExactResolve(AcpmuxRPCError(code: -32601, message: "missing")))
        #expect(AcpmuxStatusClient.shouldFallbackExactResolve(AcpmuxRPCError(code: -32602, message: "invalid")))
        #expect(!AcpmuxStatusClient.shouldFallbackExactResolve(AcpmuxRPCError(code: -32002, message: "not found")))
    }

    @Test func legacyResolveMissingErrorsBecomeNoSummary() {
        #expect(AcpmuxStatusClient.shouldTreatLegacyResolveFailureAsMissing(
            AcpmuxRPCError(code: -32002, message: "not found")))
        #expect(AcpmuxStatusClient.shouldTreatLegacyResolveFailureAsMissing(
            AcpmuxRPCError(code: -32601, message: "method missing")))
        #expect(AcpmuxStatusClient.shouldTreatLegacyResolveFailureAsMissing(
            AcpmuxRPCError(code: -32602, message: "invalid params")))
        #expect(!AcpmuxStatusClient.shouldTreatLegacyResolveFailureAsMissing(
            AcpmuxRPCError(code: -32000, message: "server error")))
    }

    @Test func legacyLocalResolveHostDoesNotMakeFolderRemote() {
        let result: [String: Any] = ["session": [
            "sessionId": "local-1", "cwd": "/work", "host": "This Mac",
        ]]
        let summary = AcpmuxStatusClient.sessionSummary("local-1", in: result)
        #expect(summary?["host"] == nil)
        #expect(AgentPaneSessionFolder(sessionId: "local-1", info: summary ?? [:])?.isLocal == true)
    }

    @Test func sessionInfoFolderUsesTheSingleRowAndPeerBoundary() {
        let remote = AgentPaneSessionFolder(sessionId: "s1", info: [
            "sessionId": "s1", "cwd": "/work", "peer": "gcp-codex-lane-1",
        ])
        #expect(remote == AgentPaneSessionFolder(cwd: "/work", isLocal: false))
        let local = AgentPaneSessionFolder(sessionId: "s2", info: ["sessionId": "s2", "cwd": "/work"])
        #expect(local?.isLocal == true)
        let resolvedLocal = AgentPaneSessionFolder(sessionId: "s3", info: [
            "sessionId": "s3", "cwd": "/work", "hostKind": "local", "peer": NSNull(),
        ])
        #expect(resolvedLocal?.isLocal == true)
        let hostOnly = AgentPaneSessionFolder(sessionId: "s4", info: [
            "sessionId": "s4", "cwd": "/work", "host": "remote",
        ])
        #expect(hostOnly?.isLocal == false)
    }
}
