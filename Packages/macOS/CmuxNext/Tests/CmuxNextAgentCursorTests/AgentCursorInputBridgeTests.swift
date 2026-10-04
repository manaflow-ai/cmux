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

    /// Two contents: A owns tab_7 and the desktop window, B owns tab_9.
    /// Every target named in `leased` is leased to its session first.
    private func bridge(owning targets: Set<String> = ["tab_7", "tab_9", "cua:24954:25760"],
                        leased: [String: String] = ["tab_7": "s1", "tab_9": "s3", "cua:24954:25760": "s2"])
        -> (AgentCursorInputBridge, Recorder, Recorder) {
        let a = Recorder()
        let b = Recorder()
        let publisherA = AgentCursorPublisher(renderer: a)
        let publisherB = AgentCursorPublisher(renderer: b)
        let bridge = AgentCursorInputBridge(
            publisher: { target in
                guard targets.contains(target) else { return nil }
                return target == "tab_9" ? publisherB : publisherA
            },
            publishers: { [publisherA, publisherB] })
        for (target, session) in leased { bridge.leaseChanged(target: target, session: session, wireState: "driving") }
        return (bridge, a, b)
    }

    @Test func everyValidVectorReachesTheOwningPublisherInOrder() throws {
        let vectors = try Self.vectors()
        let (bridge, a, b) = bridge()
        for data in vectors.valid { bridge.receive(data) }
        let expected = try vectors.valid.map { try AutomationInputEvent.decode($0) }
        #expect(a.events == expected.filter { $0.targetID != "tab_9" })
        #expect(b.events == expected.filter { $0.targetID == "tab_9" })
        #expect(bridge.counts == .init(published: expected.count))
    }

    @Test func everyInvalidVectorIsRejectedAndCounted() throws {
        let vectors = try Self.vectors()
        let (bridge, a, b) = bridge()
        for data in vectors.invalid { bridge.receive(data) }
        #expect(a.events.isEmpty && b.events.isEmpty)
        #expect(bridge.counts.rejected == vectors.invalid.count)
    }

    @Test func aMissingEventIsDetectedCountedAndTheNewestStillDrawn() {
        let (bridge, recorder, _) = bridge()
        bridge.receive(Self.event(seq: 0))
        bridge.receive(Self.event(seq: 1))
        bridge.receive(Self.event(seq: 4))
        bridge.receive(Self.event(seq: 5))
        #expect(bridge.counts.gaps == 1, "one gap")
        #expect(bridge.counts.missing == 2, "seq 2 and 3 never arrived")
        #expect(recorder.events.map(\.seq) == [0, 1, 4, 5], "the cursor goes to the newest point")
    }

    @Test func aReplayedEventIsNotDrawnTwice() {
        let (bridge, recorder, _) = bridge()
        bridge.receive(Self.event(seq: 0))
        bridge.receive(Self.event(seq: 1))
        bridge.receive(Self.event(seq: 1))
        #expect(recorder.events.map(\.seq) == [0, 1])
        #expect(bridge.counts.replays == 1)
        #expect(bridge.counts.gaps == 0)
    }

    @Test func seqZeroStartsTheSessionAgain() {
        let (bridge, recorder, _) = bridge()
        for seq in 0...3 { bridge.receive(Self.event(seq: seq)) }
        bridge.receive(Self.event(seq: 0))
        bridge.receive(Self.event(seq: 1))
        #expect(recorder.events.map(\.seq) == [0, 1, 2, 3, 0, 1], "a new lease session draws from its first event")
        #expect(bridge.counts.gaps == 0)
    }

    @Test func gapsArePerSession() {
        let (bridge, a, b) = bridge(leased: ["tab_7": "a", "tab_9": "b"])
        bridge.receive(Self.event(session: "a", target: "tab_7", seq: 0))
        bridge.receive(Self.event(session: "b", target: "tab_9", seq: 0))
        bridge.receive(Self.event(session: "a", target: "tab_7", seq: 1))
        bridge.receive(Self.event(session: "b", target: "tab_9", seq: 1))
        #expect(bridge.counts.gaps == 0)
        #expect(a.events.count == 2 && b.events.count == 2)
    }

    /// Only the session that holds the target's lease draws there.
    @Test func anEventOfASessionWithoutTheLeaseIsNotDrawn() {
        let (bridge, recorder, _) = bridge(leased: ["tab_7": "s1"])
        bridge.receive(Self.event(session: "s2", target: "tab_7", seq: 0))
        bridge.receive(Self.event(session: "s1", target: "tab_9", seq: 0))
        #expect(recorder.events.isEmpty)
        #expect(bridge.counts.unleased == 2)
        bridge.receive(Self.event(session: "s1", target: "tab_7", seq: 0))
        #expect(recorder.events.map(\.seq) == [0])
    }

    /// A session name used again after its lease ended draws in every
    /// content, also one where the old session reached a higher seq.
    @Test func anEndedSessionIsForgottenByEveryPublisher() {
        let (bridge, a, b) = bridge(leased: ["tab_7": "s"])
        for seq in 0...50 { bridge.receive(Self.event(session: "s", target: "tab_7", seq: seq)) }
        bridge.leaseChanged(target: "tab_7", session: nil, wireState: nil)
        bridge.leaseChanged(target: "tab_9", session: "s", wireState: "driving")
        bridge.leaseChanged(target: "tab_7", session: "s", wireState: "driving")
        bridge.receive(Self.event(session: "s", target: "tab_9", seq: 0))
        bridge.receive(Self.event(session: "s", target: "tab_7", seq: 1))
        #expect(b.events.map(\.seq) == [0])
        #expect(a.events.last?.seq == 1, "content A draws the new session although the old one reached seq 50")
        #expect(a.events.count == 52)
    }

    /// Gap sizes come from the wire: two sessions that each skip almost
    /// 2^64 events saturate the count instead of trapping.
    @Test func hugeGapsDoNotOverflow() {
        let (bridge, a, b) = bridge()
        func huge(_ session: String, _ target: String) -> Data {
            Data(#"{"v":1,"session_id":"\#(session)","target_id":"\#(target)","seq":18000000000000000000,"kind":"key","space":"viewport","t_ms":1}"#.utf8)
        }
        bridge.receive(Self.event(session: "s1", target: "tab_7", seq: 0))
        bridge.receive(huge("s1", "tab_7"))
        bridge.receive(Self.event(session: "s3", target: "tab_9", seq: 0))
        bridge.receive(huge("s3", "tab_9"))
        #expect(bridge.counts.gaps == 2)
        #expect(bridge.counts.missing == .max, "saturates")
        #expect(a.events.count == 2 && b.events.count == 2)
    }

    @Test func aTargetNoContentOwnsIsCountedNotDrawn() {
        let (bridge, recorder, _) = bridge(owning: [])
        bridge.receive(Self.event(seq: 0))
        #expect(recorder.events.isEmpty)
        #expect(bridge.counts.unrouted == 1)
    }

    @Test func aSessionWithNoLeaseLeftIsForgotten() {
        let (bridge, recorder, _) = bridge(leased: ["tab_7": "s1"])
        bridge.receive(Self.event(seq: 0))
        bridge.receive(Self.event(seq: 1))
        bridge.leaseChanged(target: "tab_7", session: nil, wireState: nil)
        #expect(bridge.trackedSessions == 0, "no per-session state outlives its leases")
        bridge.leaseChanged(target: "tab_7", session: "s1", wireState: "driving")
        bridge.receive(Self.event(seq: 3))
        #expect(recorder.events.map(\.seq) == [0, 1, 3], "a new lease of that name draws from its first event seen")
        #expect(bridge.counts.gaps == 0)
    }
}
