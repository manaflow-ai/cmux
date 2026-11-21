import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// A new Cloud chat's page tells its send's timeline its first prompt out and its agent's first text, each once
/// (CmuxNextCloud `CloudSendTimeline`, cmux#45953).
@Suite struct RemoteAcpmuxMilestoneTests {
    private final class Told: Sendable {
        let steps = Mutex<[String]>([])
    }

    @Test func eachMilestoneIsToldOnce() {
        let told = Told()
        let start: RemoteAcpmuxWire.Start = { _, _, _ in throw CancellationError() }
        let wire = RemoteAcpmuxWire(start: start, milestone: { step in told.steps.withLock { $0.append(step) } })
        wire.tell("prompt")
        wire.tell("prompt")
        wire.tell("first token")
        #expect(told.steps.withLock { $0 } == ["prompt", "first token"])
    }

    /// The agent's text or thinking is the first token; the person's own words echoed back, a tool call or a reply are not.
    @Test func onlyTheAgentsTextOrThinkingIsTheFirstToken() {
        let update = { (kind: String) in #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"\#(kind)"}}}"# }
        #expect(RemoteAcpmuxWire.isFirstToken(update("agent_message_chunk")))
        #expect(RemoteAcpmuxWire.isFirstToken(update("agent_thought_chunk")))
        #expect(!RemoteAcpmuxWire.isFirstToken(update("user_message_chunk")))
        #expect(!RemoteAcpmuxWire.isFirstToken(update("tool_call")))
        #expect(!RemoteAcpmuxWire.isFirstToken(#"{"jsonrpc":"2.0","id":3,"result":{"text":"agent_message_chunk"}}"#))
    }
}
