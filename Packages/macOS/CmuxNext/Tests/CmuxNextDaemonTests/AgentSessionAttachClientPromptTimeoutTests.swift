import Foundation
import Testing
@testable import CmuxNextDaemon

/// A prompt to a Cloud chat waits for that machine's daemon, which answers once its acpmux took the
/// prompt or itself after its own 30 s wait (`PROMPT_ACCEPT_TIMEOUT`, agent_session_attach.rs). The
/// client's 10 s request deadline gave up first on a busy or just-resumed machine: "Not sent: timed
/// out: agent-session-prompt (no reply within 10.0 seconds)" for a prompt that then ran (cmux#55671).
@Suite(.timeLimit(.minutes(1))) struct AgentSessionAttachClientPromptTimeoutTests {
    @Test func aPromptOutwaitsTheRequestDeadlineForTheDaemonsAcceptance() async throws {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1", "agent-session-content-v1"],
                                        replyDelays: ["agent-session-prompt": 0.8, "agent-session-events": 0.8])
        defer { daemon.stop() }
        // The deadline scaled down: a call silent for longer than it fails, a prompt does not.
        let client = AgentSessionAttachClient(surface: 7, requestTimeout: .milliseconds(250)) {
            DaemonEndpoint(socketPath: daemon.path)
        }
        _ = try await client.attach(afterSeq: nil, beforeSeq: nil, limit: nil, kinds: nil) { _, _ in }
        _ = try await client.prompt(id: "slow-text", text: "Yes, find both causes")
        _ = try await client.prompt(id: "slow-steer", text: "and this", steer: true)
        _ = try await client.prompt(id: "slow-content", content: Data(#"[{"type":"text","text":"Yes"}]"#.utf8))
        // Any other call keeps the client's own deadline.
        await #expect(throws: DaemonError.self) {
            _ = try await client.events(afterSeq: 0, beforeSeq: nil, limit: nil, kinds: nil)
        }
        await client.close()
        let prompts = daemon.frames.filter { $0["cmd"] as? String == "agent-session-prompt" }.compactMap { $0["prompt_id"] as? String }
        #expect(prompts == ["slow-text", "slow-steer", "slow-content"])
    }

    @Test func thePromptDeadlineOutlastsTheDaemonsOwnWaitForAcpmux() {
        // `PROMPT_ACCEPT_TIMEOUT` (30 s) plus the carrier: the daemon always answers first.
        #expect(AgentSessionAttachClient.promptTimeout > .seconds(30))
    }
}
