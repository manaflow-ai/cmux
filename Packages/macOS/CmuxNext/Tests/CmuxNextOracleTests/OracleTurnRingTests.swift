#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextOracle
import Testing

/// The recorder's ring: a full ring of 256 keeps the newest, counts what it dropped
/// and never reuses a sequence; a reader asks for what came after its last sequence; an entry carries
/// the facet values for the runner to normalize. Run: `swift test --filter OracleTurnRingTests`.
struct OracleTurnRingTests {
    @Test func aFullRingKeepsTheNewestAndCountsWhatItDropped() {
        var ring = OracleTurnRing()
        #expect(ring.capacity == 256)
        for index in 0..<300 {
            ring.append(kind: .turn, label: "a\(index)", origin: "cli", ran: true, facets: ["topology": OracleValue(index)])
        }
        let all = ring.checkpoints()
        #expect(all.count == 256)
        #expect(ring.dropped == 44)
        #expect(all.first?.sequence == 45)
        #expect(all.last?.sequence == 300)
        #expect(all.map(\.sequence) == Array(45...300))
        #expect(all.last?.label == "a299")
        #expect(all.last?.facets == ["topology": 299])
    }

    @Test func aReaderGetsWhatCameAfterItsLastSequence() {
        var ring = OracleTurnRing(capacity: 4)
        for index in 1...6 { ring.append(kind: .mark, label: "m\(index)", facets: nil, failure: "none") }
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
        ring.append(kind: .turn, label: "a", facets: nil)
        ring.clear()
        #expect(ring.checkpoints().isEmpty)
        let next = ring.append(kind: .turn, label: "b", facets: nil)
        #expect(next.sequence == 2)
        #expect(ring.checkpoints().map(\.label) == ["b"])
    }

    @Test func anEntryCarriesTheFacetValuesOrTheFailure() {
        var ring = OracleTurnRing()
        let facets: OracleValue = ["focus": ["pane": "pane_1"], "topology": ["sequence": 7, "panes": 2]]
        let turn = ring.append(kind: .turn, label: "newTab", origin: "user", ran: false, facets: facets).value
        #expect(turn["kind"] == "turn")
        #expect(turn["label"] == "newTab")
        #expect(turn["origin"] == "user")
        #expect(turn["ran"] == false)
        #expect(turn["sequence"] == 1)
        // Raw values, counters included: normalize.py drops what the schema marks volatile.
        #expect(turn["facets"] == facets)
        #expect(turn["failure"] == nil)

        let failed = ring.append(kind: .mark, label: "settled", facets: nil, failure: "facet topology: tree gone").value
        #expect(failed["facets"] == nil)
        #expect(failed["failure"] == "facet topology: tree gone")
        #expect(failed["origin"] == nil)
        #expect(failed["ran"] == nil)
    }
}
#endif
