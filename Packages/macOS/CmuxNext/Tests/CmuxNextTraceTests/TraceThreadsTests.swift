import CmuxNextCompat
@testable import CmuxNextTrace
import Darwin
import Testing

/// The ring's thread table: whole 256-entry pages, generations for reused entries,
/// overflow counted in the header, and every chunk's writer named from the ring alone.
@Suite(.serialized)
struct TraceThreadsTests {
    private static func ring(threads: Int, chunks: Int) -> TraceRing {
        TraceRing(sizes: TraceRing.Sizes(nameCapacity: 16, threadCapacity: threads, chunkCount: chunks),
                  identity: TraceRing.Identity(pid: 1, role: .app))
    }

    /// Runs `count` threads in batches of `batch`; the threads of a batch are all live at once (each writes,
    /// then waits for the rest of its batch before it exits).
    private static func writeFromThreads(_ ring: TraceRing, count: Int, batch: Int) {
        for first in stride(from: 0, to: count, by: batch) {
            let size = min(batch, count - first)
            let wrote = SharedCount()
            runOnThreads(size) { offset in
                let tag = first + offset
                pthread_setname_np("trace-worker-\(tag)")
                ring.write(name: 1, phase: .instant, timestamp: UInt64(tag + 1), arg0: UInt64(tag))
                wrote.value.add(1, ordering: .acquiringAndReleasing)
                while wrote.value.load(ordering: .acquiring) < size { sched_yield() }
            }
        }
    }

    @Test("A thread table is whole 256-entry pages")
    func pagesOf256() {
        #expect(TraceRing.Sizes(nameCapacity: 16, threadCapacity: 2000, chunkCount: 1).threadCapacity == 2048)
        #expect(TraceRing.Sizes(nameCapacity: 16, threadCapacity: 1, chunkCount: 1).threadCapacity == 256)
        #expect(TraceRing.pageBytes / TraceRing.entryBytes == 256)
    }

    @Test("2,000 threads register with no overflow, each under its own name, tid and entry")
    func twoThousandThreads() throws {
        let count = 2000
        let ring = Self.ring(threads: 2048, chunks: 4096)
        Self.writeFromThreads(ring, count: count, batch: 100)
        let image = try #require(ring.decodedImage())
        #expect(image.header.threadOverflow == 0)
        #expect(ring.counters.threadOverflow == 0)
        #expect(ring.counters.recordsDropped == 0)
        #expect(image.threads.count == count)
        #expect(image.threads.allSatisfy { $0.state == .exited && $0.generation == 0 })
        #expect(Set(image.threads.map(\.tid)).count == count)
        #expect(image.records.count == count)
        for record in image.records {
            #expect(image.threadLabel(of: record) == "trace-worker-\(record.arg0)")
        }
        #expect(Set(image.records.map(\.threadIndex)).count == count)
    }

    /// Fresh entries go first; once none is left, a new thread takes an exited entry with the next
    /// generation. The earlier occupant's chunk still names the entry, and the generation tells the two apart.
    @Test("A reused entry takes the next generation, and the earlier occupant's records keep their own")
    func generations() throws {
        let ring = Self.ring(threads: 256, chunks: 512)
        Self.writeFromThreads(ring, count: 256, batch: 64)
        runOnThreads(1) { _ in
            pthread_setname_np("second-occupant")
            ring.write(name: 1, phase: .instant, timestamp: 10_000, arg0: 10_000)
        }
        let image = try #require(ring.decodedImage())
        #expect(image.header.threadOverflow == 0)
        let reused = try #require(image.threads.first { $0.name == "second-occupant" })
        #expect(reused.index == 0, "the first exited entry")
        #expect(reused.generation == 1)
        #expect(image.threads.count == 256)
        let newest = try #require(image.records.last)
        #expect(newest.arg0 == 10_000)
        #expect(newest.threadIndex == 0 && newest.threadGeneration == 1)
        #expect(image.threadLabel(of: newest) == "second-occupant")
        let earlier = try #require(image.records.first { $0.threadIndex == 0 && $0.threadGeneration == 0 })
        #expect(image.thread(of: earlier) == nil)
        #expect(image.threadLabel(of: earlier) == "thread 0 (generation 0)")
    }

    @Test("A thread that finds the table full writes thread 0xFFFFFFFF and is counted")
    func overflow() throws {
        let ring = Self.ring(threads: 256, chunks: 512)
        let wrote = SharedCount()
        let release = SharedCount()
        runOnThreads(257) { tag in
            if tag < 256 {
                ring.write(name: 1, phase: .instant, timestamp: UInt64(tag + 1), arg0: UInt64(tag))
                wrote.value.add(1, ordering: .acquiringAndReleasing)
                while release.value.load(ordering: .acquiring) == 0 { sched_yield() }
                return
            }
            while wrote.value.load(ordering: .acquiring) < 256 { sched_yield() }
            ring.write(name: 1, phase: .instant, timestamp: 1_000, arg0: 1_000)
            release.value.store(1, ordering: .releasing)
        }
        let image = try #require(ring.decodedImage())
        #expect(image.header.threadOverflow == 1)
        let full = try #require(image.records.first { $0.arg0 == 1_000 })
        #expect(full.threadIndex == TraceRing.noThread)
        #expect(image.thread(of: full) == nil)
        #expect(image.threadLabel(of: full) == "thread table full")
        #expect(image.threads.count == 256)
    }

    @Test("An unnamed thread is labeled by its entry")
    func unnamed() throws {
        let ring = TraceRing(sizes: TraceRing.Sizes(nameCapacity: 16, threadCapacity: 256, chunkCount: 4),
                             identity: TraceRing.Identity(pid: 1, role: .app)) {
            TraceRing.ThreadIdentity(tid: 7, qos: 0x15, name: "")
        }
        ring.write(name: 1, phase: .instant, timestamp: 1)
        let image = try #require(ring.decodedImage())
        let record = try #require(image.records.first)
        #expect(image.threadLabel(of: record) == "thread 0")
        #expect(image.threads.map(\.tid) == [7])
        #expect(image.threads.map(\.qos) == [0x15])
        #expect(image.threads.map(\.state) == [.live])
    }
}
