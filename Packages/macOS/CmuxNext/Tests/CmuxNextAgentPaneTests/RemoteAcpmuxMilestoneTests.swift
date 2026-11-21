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

    /// An acpmux record as the daemon pushes it (`EventRecord`: its `kind` is the update's `sessionUpdate`).
    private static func record(_ kind: String, text: String = "hi") -> Data {
        Data(#"{"sessionId":"s","seq":7,"at":1,"dir":"in","kind":"\#(kind)","msg":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"\#(kind)","content":{"type":"text","text":"\#(text)"}}}}}"#.utf8)
    }

    /// The agent's text or thinking is the first token; the person's own words echoed back, a tool call or a status are
    /// not, and neither is a record that only quotes the kind in its text.
    @Test func onlyTheAgentsTextOrThinkingIsTheFirstToken() throws {
        let read = { (data: Data) in try JSONSerialization.jsonObject(with: data) }
        #expect(RemoteAcpmuxWire.isFirstToken(try read(Self.record("agent_message_chunk"))))
        #expect(RemoteAcpmuxWire.isFirstToken(try read(Self.record("agent_thought_chunk"))))
        #expect(!RemoteAcpmuxWire.isFirstToken(try read(Self.record("user_message_chunk"))))
        #expect(!RemoteAcpmuxWire.isFirstToken(try read(Self.record("tool_call"))))
        #expect(!RemoteAcpmuxWire.isFirstToken(try read(Self.record("user_message_chunk", text: "agent_message_chunk"))))
        #expect(!RemoteAcpmuxWire.isFirstToken(try read(Data(#"{"seq":1,"at":1,"dir":"mux","kind":"status","msg":{"status":"running"}}"#.utf8))))
        #expect(!RemoteAcpmuxWire.isFirstToken("agent_message_chunk"))
    }

    /// The records the daemon pushes, through the wire's own path to the page: the first token is told at the agent's
    /// first text, once, and the page still gets every record. (The frame the page gets is written with
    /// `session\/update`; a check of the frame's text for `"session/update"` never told it.)
    @Test func theAgentsFirstPushedTextTellsTheFirstTokenOnce() async throws {
        let told = Told(), frames = Told()
        let start: RemoteAcpmuxWire.Start = { _, _, _ in throw CancellationError() }
        let wire = RemoteAcpmuxWire(start: start, milestone: { step in told.steps.withLock { $0.append(step) } })
        try await wire.open(onFrame: { frame in frames.steps.withLock { $0.append(frame) } }, onClose: { _, _ in })
        wire.pushed(.record(Self.record("user_message_chunk")))
        wire.pushed(.record(Self.record("tool_call")))
        #expect(told.steps.withLock { $0 }.isEmpty)
        wire.pushed(.record(Self.record("agent_thought_chunk")))
        wire.pushed(.record(Self.record("agent_message_chunk")))
        #expect(told.steps.withLock { $0 } == ["first token"])
        #expect(frames.steps.withLock { $0 }.filter { $0.contains(#""_acpmux\/event""#) || $0.contains(#""_acpmux/event""#) }.count == 4)
    }

    /// The first token can reach the page in a page of records (an attach's first page, or the replay after an
    /// attachment that dropped) instead of as a push: it is told from there too, once.
    @Test func aPageOfRecordsThatHoldsTheAgentsTextTellsTheFirstToken() throws {
        let told = Told()
        let start: RemoteAcpmuxWire.Start = { _, _, _ in throw CancellationError() }
        let wire = RemoteAcpmuxWire(start: start, milestone: { step in told.steps.withLock { $0.append(step) } })
        let page = { (kinds: [String]) in ["events": try kinds.map { try JSONSerialization.jsonObject(with: Self.record($0)) }, "hasMore": false] as [String: Any] }
        wire.tellFirstToken(in: nil)
        wire.tellFirstToken(in: ["session": ["sessionId": "s"]])
        wire.tellFirstToken(in: try page(["user_message_chunk", "tool_call"]))
        #expect(told.steps.withLock { $0 }.isEmpty)
        wire.tellFirstToken(in: try page(["user_message_chunk", "agent_message_chunk"]))
        wire.tellFirstToken(in: try page(["agent_thought_chunk"]))
        wire.pushed(.record(Self.record("agent_message_chunk")))
        #expect(told.steps.withLock { $0 } == ["first token"])
    }

    /// A wire with no timeline to tell tells nothing and still sends the page its records.
    @Test func aWireWithNoMilestoneOnlyForwards() async throws {
        let frames = Told()
        let start: RemoteAcpmuxWire.Start = { _, _, _ in throw CancellationError() }
        let wire = RemoteAcpmuxWire(start: start)
        try await wire.open(onFrame: { frame in frames.steps.withLock { $0.append(frame) } }, onClose: { _, _ in })
        wire.pushed(.record(Self.record("agent_message_chunk")))
        #expect(frames.steps.withLock { $0 }.count == 1)
    }
}
