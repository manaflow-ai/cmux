#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextOracle
import Testing

/// The recorder's ring and hashes (p15-oracle-032): a full ring of 256 keeps the newest, counts what it
/// dropped and never reuses a sequence; a reader asks for what came after its last sequence; equal
/// snapshots hash equal whatever order their keys were built in, and canonical JSON is the compact,
/// key-sorted text normalize.py hashes. Run: `swift test --filter OracleTurnRingTests`.
struct OracleTurnRingTests {
    private func hash(_ value: OracleValue) -> OracleSnapshotHash {
        OracleSnapshotHash(["topology": value])
    }

    @Test func aFullRingKeepsTheNewestAndCountsWhatItDropped() {
        var ring = OracleTurnRing()
        #expect(ring.capacity == 256)
        for index in 0..<300 {
            ring.append(kind: .turn, label: "a\(index)", origin: "cli", ran: true, snapshot: hash(OracleValue(index)))
        }
        let all = ring.checkpoints()
        #expect(all.count == 256)
        #expect(ring.dropped == 44)
        #expect(all.first?.sequence == 45)
        #expect(all.last?.sequence == 300)
        #expect(all.map(\.sequence) == Array(45...300))
        #expect(all.last?.label == "a299")
    }

    @Test func aReaderGetsWhatCameAfterItsLastSequence() {
        var ring = OracleTurnRing(capacity: 4)
        for index in 1...6 { ring.append(kind: .mark, label: "m\(index)", snapshot: nil, failure: "none") }
        #expect(ring.checkpoints(after: 4).map(\.sequence) == [5, 6])
        #expect(ring.checkpoints(after: 0).map(\.sequence) == [3, 4, 5, 6])
        #expect(ring.checkpoints(after: 6).isEmpty)
        #expect(ring.checkpoints(after: .max).isEmpty)
        #expect(ring.checkpoints(last: 2).map(\.sequence) == [5, 6])
        #expect(ring.checkpoints(after: 3, last: 10).map(\.sequence) == [4, 5, 6])
        #expect(ring.checkpoints(last: 0).isEmpty)
    }

    @Test func aClearedRingGoesOnCounting() {
        var ring = OracleTurnRing(capacity: 4)
        ring.append(kind: .turn, label: "a", snapshot: nil)
        ring.clear()
        #expect(ring.checkpoints().isEmpty)
        let next = ring.append(kind: .turn, label: "b", snapshot: nil)
        #expect(next.sequence == 2)
        #expect(ring.checkpoints().map(\.label) == ["b"])
    }

    @Test func equalSnapshotsHashEqualAndADifferenceShowsInItsFacet() {
        let a = OracleSnapshotHash(["topology": ["b": 1, "a": [true, nil, "x"]], "focus": ["pane": "p1"]])
        let b = OracleSnapshotHash(["focus": ["pane": "p1"], "topology": ["a": [true, nil, "x"], "b": 1]])
        let c = OracleSnapshotHash(["focus": ["pane": "p2"], "topology": ["a": [true, nil, "x"], "b": 1]])
        #expect(a == b)
        #expect(a.whole != c.whole)
        #expect(a.facets["topology"] == c.facets["topology"])
        #expect(a.facets["focus"] != c.facets["focus"])
    }

    @Test func canonicalJSONIsCompactAndKeySorted() {
        let value: OracleValue = ["b": 2, "a": ["é", 1.5, -3, nil, false], "Z": "line\n\"q\"\u{01}"]
        #expect(value.canonicalJSON == #"{"Z":"line\n\"q\"\u0001","a":["é",1.5,-3,null,false],"b":2}"#)
        #expect(OracleValue.canonicalNumber(.infinity) == "null")
        #expect(OracleValue.canonicalNumber(4) == "4")
    }

    @Test func theFNVHashIsTheStandardOne() {
        // FNV-1a 64 test vectors (http://www.isthe.com/chongo/tech/comp/fnv/).
        #expect(OracleSnapshotHash.fnv1a("") == 0xcbf2_9ce4_8422_2325)
        #expect(OracleSnapshotHash.fnv1a("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(OracleSnapshotHash.hex(0xab) == "fnv1a64:00000000000000ab")
    }

    @Test func aCheckpointAnswersWithHashesOnly() {
        var ring = OracleTurnRing()
        let checkpoint = ring.append(kind: .turn, label: "newTab", origin: "user", ran: false,
                                     snapshot: OracleSnapshotHash(["focus": "secret"]))
        let value = checkpoint.value
        #expect(value["kind"] == "turn")
        #expect(value["label"] == "newTab")
        #expect(value["origin"] == "user")
        #expect(value["ran"] == false)
        #expect(value["sequence"] == 1)
        #expect(value["hash"]?.stringValueForTest?.hasPrefix("fnv1a64:") == true)
        #expect(value["facets"]?["focus"]?.stringValueForTest?.hasPrefix("fnv1a64:") == true)
        #expect(!value.canonicalJSON.contains("secret"))
    }
}

private extension OracleValue {
    var stringValueForTest: String? {
        if case .string(let text) = self { return text }
        return nil
    }
}
#endif
