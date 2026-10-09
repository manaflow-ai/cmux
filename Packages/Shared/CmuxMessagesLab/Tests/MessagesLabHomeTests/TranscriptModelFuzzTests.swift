import AppKit
import Testing
@testable import MessagesLabHome

/// Crash program (index_subscript / int_conversion): the transcript model's tail updates,
/// splices and snapshots with a start or count from an older model (a tail start computed
/// before the rows changed) refuse or clamp instead of trapping. Seeded.
@MainActor @Suite struct TranscriptModelFuzzTests {
    static func spec(_ key: String, _ h: CGFloat = 20) -> RowSpec { RowSpec(key: key, kind: .typing, gap: 2, height: h) }

    @Test func aTailStartPastTheRowsDoesNotTrap() {
        let m = TranscriptModel()
        m.set((0..<5).map { Self.spec("k\($0)") }, at: 0, ghosts: false)
        m.setTail(from: 9, liveCut: 2, [Self.spec("n1")], at: 1, ghosts: true)
        m.setTail(from: 4, liveCut: 1, [Self.spec("n2")], at: 2, ghosts: true)
        #expect(m.offsets.count == m.count + 1)
        #expect(m.contentTop(99) == 0)
        #expect(m.contentTop(-1) == 0)
    }

    @Test func aSpliceWithCountsFromAnotherModelDoesNotTrap() {
        let m = TranscriptModel()
        m.set((0..<4).map { Self.spec("k\($0)") }, at: 0, ghosts: false)
        m.splice(dropHead: -2, newHead: [Self.spec("h")], dropTail: -3, newTail: [Self.spec("t")], at: 1)
        m.splice(dropHead: 1, newHead: [], dropTail: 9, newTail: [], at: 2)
        #expect(m.offsets.count == m.count + 1)
    }

    @Test func aTailSnapshotReadsNothingOutsideItsRows() {
        let m = TranscriptModel()
        m.set((0..<6).map { Self.spec("k\($0)") }, at: 0, ghosts: false)
        let snap = m.tailSnapshot(from: 3)
        #expect(snap.row(40) == nil)
        #expect(snap.row(-1) == nil)
        let late = m.tailSnapshot(from: 20)
        _ = late.keys
        _ = late.contentTop("k1")
    }

    @Test func randomTailUpdatesKeepPositionsConsistent() {
        var seed: UInt64 = 0xA11CE
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(truncatingIfNeeded: (seed >> 33) % UInt64(max(1, n))) }
        let m = TranscriptModel()
        var t = 0.0
        for _ in 0..<600 {
            t += 0.3
            let keys = (0..<next(14)).map { _ in "k\(next(25))" }
            var seen = Set<String>()
            let specs = keys.filter { seen.insert($0).inserted }.map { Self.spec($0, CGFloat(next(40))) }
            switch next(4) {
            case 0: m.set(specs, at: t, ghosts: next(2) == 0)
            case 1:
                let cut = next(m.liveCount + 3) - 1
                if let m0 = m.tailStart(fromLive: max(0, cut), specs) { m.setTail(from: m0 + next(3) - 1, liveCut: max(0, cut), specs, at: t, ghosts: true) }
            case 2: m.splice(dropHead: next(4) - 1, newHead: Array(specs.prefix(2)), dropTail: next(4) - 1, newTail: Array(specs.suffix(1)), at: t)
            default: m.dropGhosts(before: t - Double(next(3)))
            }
            #expect(m.offsets.count == m.count + 1)
            for i in -1...(m.count + 1) { #expect(m.contentTop(i).isFinite) }
            _ = m.range(-50, m.total + 50)
        }
    }
}
