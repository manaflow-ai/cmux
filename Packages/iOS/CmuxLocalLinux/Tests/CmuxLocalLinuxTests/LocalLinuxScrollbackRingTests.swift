import Foundation
import Testing

@testable import CmuxLocalLinux

@Suite("Local Linux scrollback ring")
struct LocalLinuxScrollbackRingTests {
    @Test("an empty ring starts at sequence zero")
    func emptyRingStartsAtZero() async {
        let ring = LocalLinuxScrollbackRing(limit: 8)

        let snapshot = await ring.snapshot(from: nil)

        #expect(snapshot.baseSequence == 0)
        #expect(snapshot.currentSequence == 0)
        #expect(snapshot.bytes.isEmpty)
        #expect(await ring.currentSequence == 0)
    }

    @Test("append stamps the original start and advances the current sequence")
    func appendStampsSequenceRange() async {
        let ring = LocalLinuxScrollbackRing(limit: 8)

        let first = await ring.append(Data("abc".utf8))
        let second = await ring.append(Data("de".utf8))

        #expect(first.baseSequence == 0)
        #expect(first.startSequence == 0)
        #expect(first.currentSequence == 3)
        #expect(second.baseSequence == 0)
        #expect(second.startSequence == 3)
        #expect(second.currentSequence == 5)
        #expect(await ring.currentSequence == 5)
    }

    @Test("a cursor selects a suffix of retained output")
    func cursorSelectsRetainedSuffix() async {
        let ring = LocalLinuxScrollbackRing(limit: 8)
        _ = await ring.append(Data("abcde".utf8))

        let snapshot = await ring.snapshot(from: 2)

        #expect(snapshot.baseSequence == 2)
        #expect(snapshot.currentSequence == 5)
        #expect(String(decoding: snapshot.bytes, as: UTF8.self) == "cde")
    }

    @Test("eviction advances the retained base and clamps stale cursors")
    func evictionAdvancesBaseAndClampsCursors() async {
        let ring = LocalLinuxScrollbackRing(limit: 4)
        _ = await ring.append(Data("abc".utf8))
        let stamp = await ring.append(Data("def".utf8))

        #expect(stamp.startSequence == 3)
        #expect(stamp.baseSequence == 2)
        #expect(stamp.currentSequence == 6)

        let cold = await ring.snapshot(from: nil)
        #expect(cold.baseSequence == 2)
        #expect(cold.currentSequence == 6)
        #expect(String(decoding: cold.bytes, as: UTF8.self) == "cdef")

        let stale = await ring.snapshot(from: 0)
        #expect(stale.baseSequence == 2)
        #expect(stale.currentSequence == 6)
        #expect(String(decoding: stale.bytes, as: UTF8.self) == "cdef")

        let middle = await ring.snapshot(from: 4)
        #expect(middle.baseSequence == 4)
        #expect(middle.currentSequence == 6)
        #expect(String(decoding: middle.bytes, as: UTF8.self) == "ef")

        let future = await ring.snapshot(from: 99)
        #expect(future.baseSequence == 6)
        #expect(future.currentSequence == 6)
        #expect(future.bytes.isEmpty)
    }

    @Test("an oversized chunk retains only its newest bytes")
    func oversizedChunkIsBounded() async {
        let ring = LocalLinuxScrollbackRing(limit: 4)

        let stamp = await ring.append(Data("abcdef".utf8))
        let snapshot = await ring.snapshot(from: nil)

        #expect(stamp.startSequence == 0)
        #expect(stamp.baseSequence == 2)
        #expect(stamp.currentSequence == 6)
        #expect(snapshot.baseSequence == 2)
        #expect(snapshot.currentSequence == 6)
        #expect(String(decoding: snapshot.bytes, as: UTF8.self) == "cdef")
    }

    @Test("empty output does not consume sequence space")
    func emptyChunkDoesNotAdvance() async {
        let ring = LocalLinuxScrollbackRing(limit: 4)

        let stamp = await ring.append(Data())
        let snapshot = await ring.snapshot(from: nil)

        #expect(stamp.baseSequence == 0)
        #expect(stamp.startSequence == 0)
        #expect(stamp.currentSequence == 0)
        #expect(snapshot.bytes.isEmpty)
    }

    @Test("a zero-sized ring still reports consumed sequence bytes")
    func zeroLimitRetainsNothingButAdvancesSequence() async {
        let ring = LocalLinuxScrollbackRing(limit: 0)

        let stamp = await ring.append(Data("abc".utf8))
        let snapshot = await ring.snapshot(from: nil)

        #expect(stamp.startSequence == 0)
        #expect(stamp.baseSequence == 3)
        #expect(stamp.currentSequence == 3)
        #expect(snapshot.baseSequence == 3)
        #expect(snapshot.currentSequence == 3)
        #expect(snapshot.bytes.isEmpty)
    }

    @Test("a negative retention budget is treated as zero")
    func negativeLimitIsClamped() async {
        let ring = LocalLinuxScrollbackRing(limit: -1)

        let stamp = await ring.append(Data("x".utf8))
        let snapshot = await ring.snapshot(from: nil)

        #expect(stamp.baseSequence == 1)
        #expect(stamp.currentSequence == 1)
        #expect(snapshot.baseSequence == 1)
        #expect(snapshot.currentSequence == 1)
        #expect(snapshot.bytes.isEmpty)
    }
}
