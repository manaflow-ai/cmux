import CmuxAgentCursor
@testable import CmuxNextAgentCursor
import Foundation
import Testing

/// `input {event}` frames to the owning content's `AgentCursorPublisher`:
/// decoded and checked against schemas/automation-input, seq gaps detected
/// and counted, never ignored.
@MainActor
@Suite struct AgentCursorInputBridgeTests {
    final class Recorder: AgentCursorRendering {
        var events: [AutomationInputEvent] = []
        func render(_ event: AutomationInputEvent) { events.append(event) }
    }

    struct Vectors {
        var valid: [Data]
        var invalid: [Data]
    }

    static func vectors() throws -> Vectors {
        // Tests/CmuxNextAgentCursorTests/<file> -> repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appending(path: "schemas/automation-input/vectors.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let valid = try #require(root["valid"] as? [[String: Any]])
        let invalid = try #require(root["invalid"] as? [[String: Any]])
        return try Vectors(
            valid: valid.map { try JSONSerialization.data(withJSONObject: $0) },
            invalid: invalid.map { try JSONSerialization.data(withJSONObject: try #require($0["event"])) })
    }

    static func event(session: String = "s1", target: String = "tab_7", seq: Int) -> Data {
        Data(#"{"v":1,"session_id":"\#(session)","target_id":"\#(target)","seq":\#(seq),"kind":"click","space":"viewport","point":{"x":1,"y":2},"t_ms":\#(seq)}"#.utf8)
    }

    /// One recorder per target: the publisher of the content that owns it.
    private func bridge(owning targets: Set<String> = ["tab_7", "tab_9", "cua:24954:25760"]) -> (AgentCursorInputBridge, Recorder) {
        let recorder = Recorder()
        let publisher = AgentCursorPublisher(renderer: recorder)
        return (AgentCursorInputBridge { targets.contains($0) ? publisher : nil }, recorder)
    }

    @Test func everyValidVectorReachesTheOwningPublisherInOrder() throws {
        let vectors = try Self.vectors()
        let (bridge, recorder) = bridge()
        for data in vectors.valid { bridge.receive(data) }
        let expected = try vectors.valid.map { try AutomationInputEvent.decode($0) }
        #expect(recorder.events == expected)
        #expect(bridge.counts == .init(published: expected.count))
    }

    @Test func everyInvalidVectorIsRejectedAndCounted() throws {
        let vectors = try Self.vectors()
        let (bridge, recorder) = bridge()
        for data in vectors.invalid { bridge.receive(data) }
        #expect(recorder.events.isEmpty)
        #expect(bridge.counts.rejected == vectors.invalid.count)
    }

    @Test func aMissingEventIsDetectedCountedAndTheNewestStillDrawn() {
        let (bridge, recorder) = bridge()
        bridge.receive(Self.event(seq: 0))
        bridge.receive(Self.event(seq: 1))
        bridge.receive(Self.event(seq: 4))
        bridge.receive(Self.event(seq: 5))
        #expect(bridge.counts.gaps == 1, "one gap")
        #expect(bridge.counts.missing == 2, "seq 2 and 3 never arrived")
        #expect(recorder.events.map(\.seq) == [0, 1, 4, 5], "the cursor goes to the newest point")
    }

    @Test func aReplayedEventIsNotDrawnTwice() {
        let (bridge, recorder) = bridge()
        bridge.receive(Self.event(seq: 0))
        bridge.receive(Self.event(seq: 1))
        bridge.receive(Self.event(seq: 1))
        #expect(recorder.events.map(\.seq) == [0, 1])
        #expect(bridge.counts.replays == 1)
        #expect(bridge.counts.gaps == 0)
    }

    @Test func seqZeroStartsTheSessionAgain() {
        let (bridge, recorder) = bridge()
        for seq in 0...3 { bridge.receive(Self.event(seq: seq)) }
        bridge.receive(Self.event(seq: 0))
        bridge.receive(Self.event(seq: 1))
        #expect(recorder.events.map(\.seq) == [0, 1, 2, 3, 0, 1], "a new lease session draws from its first event")
        #expect(bridge.counts.gaps == 0)
    }

    @Test func gapsArePerSession() {
        let (bridge, recorder) = bridge()
        bridge.receive(Self.event(session: "a", seq: 0))
        bridge.receive(Self.event(session: "b", seq: 0))
        bridge.receive(Self.event(session: "a", seq: 1))
        bridge.receive(Self.event(session: "b", seq: 1))
        #expect(bridge.counts.gaps == 0)
        #expect(recorder.events.count == 4)
    }

    @Test func aTargetNoContentOwnsIsCountedNotDrawn() {
        let (bridge, recorder) = bridge(owning: [])
        bridge.receive(Self.event(seq: 0))
        #expect(recorder.events.isEmpty)
        #expect(bridge.counts.unrouted == 1)
    }

    @Test func aSessionWithNoLeaseLeftIsForgotten() {
        let (bridge, recorder) = bridge()
        bridge.receive(Self.event(seq: 0))
        bridge.receive(Self.event(seq: 1))
        bridge.leaseChanged(target: "tab_7", session: "s1", wireState: "driving")
        bridge.leaseChanged(target: "tab_7", session: nil, wireState: nil)
        #expect(bridge.trackedSessions == 0, "no per-session state outlives its leases")
        bridge.receive(Self.event(seq: 0))
        #expect(recorder.events.map(\.seq) == [0, 1, 0])
    }
}
