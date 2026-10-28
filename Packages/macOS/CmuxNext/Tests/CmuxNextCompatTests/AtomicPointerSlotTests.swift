import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// `AtomicPointerSlot` over mmap words and the inlinable `Atomic` operations.
/// Run with `swift test -c release --filter AtomicPointerSlotTests`: the 8-thread tests race real
/// hardware atomics, and the instruction tests read the -O machine code of a call from this module.
///
/// Inlining notes: a relaxed load through either type, called from another module with a constant
/// ordering, is one load instruction and no call. On arm64 -O, the `relaxedSlotLoad` probe disassembles to
/// `ldr x0, [x0]` then `ret`, and `relaxedAtomicLoad` to two `ldr` (the heap word's address, then the
/// word) then `ret`. `noCallBeforeReturn` checks that from the bytes; to look by hand, run
/// `xcrun objdump -d --no-show-raw-insn` on the release test bundle and find the two closures.
@Suite(.serialized)
nonisolated struct AtomicPointerSlotTests {
    static let threads = 8
    static let perThread = 100_000

    // MARK: - Slots over mmap memory

    @Test func eightThreadsAddingToOneMappedCursorLoseNoIncrement() throws {
        let page = try SharedPage()
        let cursor = page.slot(0)
        runOnThreads(Self.threads) { _ in
            for _ in 0 ..< Self.perThread { cursor.add(1, ordering: .relaxed) }
        }
        #expect(cursor.load(ordering: .relaxed) == UInt64(Self.threads * Self.perThread))
    }

    /// Eight threads claim tickets from one cursor, as trace chunks are claimed: every ticket goes to
    /// exactly one thread.
    @Test func eightThreadsClaimEveryTicketExactlyOnce() throws {
        let total = Self.threads * Self.perThread
        let page = try SharedPage(words: total + 1)
        let cursor = page.slot(total)
        runOnThreads(Self.threads) { _ in
            for _ in 0 ..< Self.perThread {
                let ticket = cursor.add(1, ordering: .relaxed).oldValue
                page.slot(Int(ticket)).add(1, ordering: .relaxed)
            }
        }
        #expect(cursor.load(ordering: .relaxed) == UInt64(total))
        let claimedOnce = (0 ..< total).filter { page.slot($0).load(ordering: .relaxed) == 1 }.count
        #expect(claimedOnce == total)
    }

    @Test func eightThreadsCompareExchangeLoopsLoseNoUpdate() throws {
        let page = try SharedPage()
        let word = page.slot(1)
        runOnThreads(Self.threads) { _ in
            for _ in 0 ..< Self.perThread {
                var current = word.load(ordering: .relaxed)
                while true {
                    let (exchanged, original) = word.weakCompareExchange(expected: current, desired: current &+ 3, ordering: .relaxed)
                    if exchanged { break }
                    current = original
                }
            }
        }
        #expect(word.load(ordering: .relaxed) == UInt64(3 * Self.threads * Self.perThread))
    }

    /// A releasing store of a sequence publishes the payload written before it: a reader that acquires
    /// sequence `s` sees a payload of at least `s`, and the sequences it sees never go back.
    @Test func aReleasedSequencePublishesItsPayloadToAcquiringReaders() throws {
        let page = try SharedPage()
        let sequence = page.slot(0)
        let payload = page.slot(8)
        let failures = page.slot(16)
        runOnThreads(Self.threads) { index in
            if index == 0 {
                for value in 1 ... UInt64(Self.perThread) {
                    payload.store(value, ordering: .relaxed)
                    sequence.store(value, ordering: .releasing)
                }
                return
            }
            var last: UInt64 = 0
            while last < UInt64(Self.perThread) {
                let seen = sequence.load(ordering: .acquiring)
                if seen < last || payload.load(ordering: .relaxed) < seen { failures.add(1, ordering: .relaxed) }
                last = seen
            }
        }
        #expect(failures.load(ordering: .relaxed) == 0)
    }

    /// Two mappings of one file are one atomic word: what threads add through either mapping adds up,
    /// and a store through one is read through the other.
    @Test func twoMappingsOfOneFileShareTheWord() throws {
        let path = NSTemporaryDirectory() + "cmux-atomic-slot-" + UUID().uuidString
        defer { _ = unlink(path) }
        let first = try SharedPage(file: path)
        let second = try SharedPage(file: path)
        #expect(first.base != second.base)
        runOnThreads(Self.threads) { index in
            let slot = (index.isMultiple(of: 2) ? first : second).slot(2)
            for _ in 0 ..< Self.perThread { slot.add(1, ordering: .relaxed) }
        }
        #expect(second.slot(2).load(ordering: .relaxed) == UInt64(Self.threads * Self.perThread))
        first.slot(3).store(0xC0FFEE, ordering: .releasing)
        #expect(second.slot(3).load(ordering: .acquiring) == 0xC0FFEE)
    }

    @Test func singleThreadOperationsWrapAndReport() throws {
        let page = try SharedPage()
        let slot = page.slot(0)
        slot.store(UInt64.max, ordering: .relaxed)
        let added = slot.add(2, ordering: .relaxed)
        #expect(added.oldValue == UInt64.max)
        #expect(added.newValue == 1)
        let subtracted = slot.subtract(3, ordering: .acquiringAndReleasing)
        #expect(subtracted.oldValue == 1)
        #expect(subtracted.newValue == UInt64.max - 1)
        #expect(slot.exchange(7, ordering: .sequentiallyConsistent) == UInt64.max - 1)
        let refused = slot.compareExchange(expected: 6, desired: 9, ordering: .relaxed)
        #expect(!refused.exchanged)
        #expect(refused.original == 7)
        let swapped = slot.compareExchange(expected: 7, desired: 9, ordering: .acquiring)
        #expect(swapped.exchanged)
        #expect(swapped.original == 7)
        #expect(AtomicPointerSlot(page.base).load(ordering: .sequentiallyConsistent) == 9)
        #expect(page.base.pointee == 9)
    }

    // MARK: - Atomic<UInt64> and Atomic<UInt32>

    @Test func eightThreadsShareAnAtomicUInt32AndUInt64() {
        let counts = Counts()
        runOnThreads(Self.threads) { _ in
            for _ in 0 ..< Self.perThread {
                counts.narrow.add(1, ordering: .relaxed)
                counts.wide.wrappingAdd(2, ordering: .relaxed)
            }
        }
        #expect(counts.narrow.load(ordering: .relaxed) == UInt32(Self.threads * Self.perThread))
        #expect(counts.wide.load(ordering: .relaxed) == UInt64(2 * Self.threads * Self.perThread))
        counts.narrow.store(UInt32.max, ordering: .relaxed)
        let wrapped = counts.narrow.add(1, ordering: .relaxed)
        #expect(wrapped.oldValue == UInt32.max)
        #expect(wrapped.newValue == 0)
    }

    // MARK: - The -O machine code

    #if arch(arm64) && !DEBUG
    @Test func aRelaxedSlotLoadIsOneInlinedLoad() throws {
        let relaxedSlotLoad: @convention(c) (UnsafeMutablePointer<UInt64>) -> UInt64 = {
            AtomicPointerSlot($0).load(ordering: .relaxed)
        }
        let page = try SharedPage()
        page.slot(0).store(41, ordering: .relaxed)
        #expect(relaxedSlotLoad(page.base) == 41)
        let code = try #require(Self.noCallBeforeReturn(unsafeBitCast(relaxedSlotLoad, to: UnsafeRawPointer.self)))
        #expect(code.loads >= 1, "relaxedSlotLoad has no 64-bit load before ret")
    }

    @Test func aRelaxedAtomicLoadIsInlined() throws {
        let relaxedAtomicLoad: @convention(c) (UnsafeRawPointer) -> UInt64 = {
            $0.assumingMemoryBound(to: Atomic<UInt64>.self).pointee.load(ordering: .relaxed)
        }
        let atomic = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: 1)
        atomic.initialize(to: Atomic(43))
        defer {
            atomic.deinitialize(count: 1)
            atomic.deallocate()
        }
        #expect(relaxedAtomicLoad(UnsafeRawPointer(atomic)) == 43)
        let code = try #require(Self.noCallBeforeReturn(unsafeBitCast(relaxedAtomicLoad, to: UnsafeRawPointer.self)))
        #expect(code.loads >= 2, "relaxedAtomicLoad does not load the heap word inline")
    }

    /// Reads arm64 instructions from `function` up to its first `ret`. Returns the count of 64-bit
    /// `ldr` (unsigned offset) before it, or nil when it finds a call or branch first (`bl`, `b`, `blr`,
    /// `br`), or no `ret` in 32 instructions: a call means the operation was not inlined.
    static func noCallBeforeReturn(_ function: UnsafeRawPointer) -> (loads: Int, instructions: Int)? {
        var loads = 0
        for index in 0 ..< 32 {
            let word = function.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
            if word == 0xD65F_03C0 { return (loads, index) } // ret
            let immediateBranch = word & 0x7C00_0000 == 0x1400_0000 // b, bl
            let registerBranch = word & 0xFF9F_FC1F == 0xD61F_0000 // br, blr
            if immediateBranch || registerBranch { return nil }
            if word & 0xFFC0_0000 == 0xF940_0000 { loads += 1 } // ldr Xt, [Xn, #imm]
        }
        return nil
    }
    #endif
}

/// Words the test's threads share: an anonymous `MAP_SHARED` mapping, or a file mapped `MAP_SHARED`
/// (what the trace ring and the metrics store map). Unmapped when the last reference goes.
nonisolated private final class SharedPage: @unchecked Sendable { // crash-allow: base and length are set once in init; threads touch the words only through atomic slots
    let base: UnsafeMutablePointer<UInt64>
    let length: Int

    init(words: Int = 512, file: String? = nil) throws {
        let page = Int(getpagesize())
        length = (words * 8 + page - 1) / page * page
        var descriptor: Int32 = -1
        if let file {
            descriptor = open(file, O_RDWR | O_CREAT, 0o600)
            guard descriptor >= 0 else { throw SharedPageError.open(errno) }
            guard ftruncate(descriptor, off_t(length)) == 0 else {
                _ = close(descriptor)
                throw SharedPageError.truncate(errno)
            }
        }
        defer { if descriptor >= 0 { _ = close(descriptor) } }
        let flags = descriptor >= 0 ? MAP_SHARED : MAP_SHARED | MAP_ANON
        guard let mapped = mmap(nil, length, PROT_READ | PROT_WRITE, flags, descriptor, 0),
              mapped != UnsafeMutableRawPointer(bitPattern: -1) else { throw SharedPageError.map(errno) }
        base = mapped.bindMemory(to: UInt64.self, capacity: length / 8)
    }

    deinit {
        _ = munmap(base, length)
    }

    func slot(_ index: Int) -> AtomicPointerSlot {
        AtomicPointerSlot(base + index)
    }
}

nonisolated private enum SharedPageError: Error {
    case open(Int32)
    case truncate(Int32)
    case map(Int32)
}

nonisolated private final class Counts: Sendable {
    let narrow = Atomic<UInt32>(0)
    let wide = Atomic<UInt64>(0)
}

/// Runs `body(index)` on `count` new threads at once and returns when all have exited.
nonisolated private func runOnThreads(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
    var threads: [pthread_t] = []
    for index in 0 ..< count {
        let context = Unmanaged.passRetained(ThreadBody { body(index) }).toOpaque()
        var thread: pthread_t?
        let created = pthread_create(&thread, nil, { context in
            Unmanaged<ThreadBody>.fromOpaque(context).takeRetainedValue().run()
            return nil
        }, context)
        if created == 0, let thread {
            threads.append(thread)
        } else {
            Unmanaged<ThreadBody>.fromOpaque(context).release()
            Issue.record("pthread_create failed: \(created)")
        }
    }
    for thread in threads {
        _ = pthread_join(thread, nil)
    }
}

nonisolated private final class ThreadBody: Sendable {
    let run: @Sendable () -> Void

    init(_ run: @escaping @Sendable () -> Void) {
        self.run = run
    }
}
