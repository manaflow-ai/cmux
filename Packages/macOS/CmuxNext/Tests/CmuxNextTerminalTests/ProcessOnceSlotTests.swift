import CmuxNextCompat
@testable import CmuxNextTerminal
import Dispatch
import Testing

/// ProcessOnceSlot: the trace hook's app seams, given once and read from Ghostty's threads.
@Suite struct ProcessOnceSlotTests {
    nonisolated final class Seam: Sendable {
        let id: Int
        init(_ id: Int) { self.id = id }
    }

    /// What racing readers saw: the first id read, and how many reads saw another or nothing.
    nonisolated final class Reads: Sendable {
        let first = Atomic<Int>(-1)
        let reads = Atomic<Int>(0)
        let others = Atomic<Int>(0)
    }

    @Test func nothingRunsBeforeTheInstallAndTheFirstInstallStays() {
        let slot = ProcessOnceSlot<Seam>()
        var seen: [Int] = []
        #expect(!slot.isInstalled)
        slot.withObject { seen.append($0.id) }
        #expect(seen.isEmpty)

        slot.install(Seam(1))
        weak var later: Seam?
        do {
            let seam = Seam(2)
            later = seam
            slot.install(seam)
        }
        #expect(later == nil, "a later install is released at once")
        #expect(slot.isInstalled)
        slot.withObject { seen.append($0.id) }
        #expect(seen == [1])
    }

    /// Installs racing from many threads keep exactly one object, which every reader sees (TSan: `--sanitize=thread`).
    @Test func racingInstallsKeepOneObject() async {
        let slot = ProcessOnceSlot<Seam>()
        let reads = Reads()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                DispatchQueue.concurrentPerform(iterations: 16) { index in
                    slot.install(Seam(index))
                    var read: Int?
                    slot.withObject { read = $0.id }
                    reads.reads.add(1, ordering: .relaxed)
                    guard let read else {
                        reads.others.add(1, ordering: .relaxed)
                        return
                    }
                    let (stored, original) = reads.first.compareExchange(expected: -1, desired: read, ordering: .acquiringAndReleasing)
                    if !stored, original != read { reads.others.add(1, ordering: .relaxed) }
                }
                continuation.resume()
            }
        }
        #expect(reads.reads.load(ordering: .relaxed) == 16)
        #expect(reads.others.load(ordering: .relaxed) == 0)
    }
}
