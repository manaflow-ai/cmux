@testable import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The Compat sites p10-stability-075 moved behind a safe API or a checked accessor: the spawn argument list
/// helper, the bounds-checked Mach-O UUID walk, the pending call's stack fields and the detector's atomic word
/// tables.
@Suite struct CompatMemorySafetyTests {
    // MARK: withCStringList

    @Test func theListHoldsACopyOfEachStringThenNull() {
        let strings = ["/bin/sh", "-c", "echo é", ""]
        // SAFETY: the list withCStringList lends is read only inside the closure, up to its NULL.
        let read = unsafe withCStringList(strings) { list -> [String] in
            var out: [String] = []
            var index = 0
            while let entry = unsafe list[index] {
                out.append(unsafe String(cString: entry))
                index += 1
            }
            return out
        }
        #expect(read == strings)
        // SAFETY: as above; an empty list is only its NULL.
        let empty = unsafe withCStringList([]) { list in unsafe list[0] == nil }
        #expect(empty == true)
    }

    #if DEBUG
    // MARK: ImageOffsetResolver (checked load-command walk)

    @Test func aFunctionResolvesToItsImageWithTheImagesUUID() throws {
        // SAFETY: dlsym only looks the name up; the address is used as an integer.
        let symbol = try #require(unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "getpid"))
        let address = unsafe UInt(bitPattern: symbol) + 4
        var resolver = ImageOffsetResolver()
        // `resolve` is mutating (it caches the image): call it outside the macros, which take an immutable copy.
        let resolved = resolver.resolve(address)
        let frame = try #require(resolved)
        #expect(frame.offset == address - frame.base)
        #expect(frame.image.uuid != nil, "\(frame.image.name) has an LC_UUID")
        let again = resolver.resolve(address)
        #expect(again == frame, "the cached image answers the same")
        let none = resolver.resolve(1)
        #expect(none == nil)
    }

    // MARK: BlockingPendingCall (stack in its fields)

    @Test func aCapturedStackKeepsAtMostItsDepthOfFrames() {
        var call = BlockingPendingCall(kind: .fileIO, site: 0, fileID: #fileID, line: #line)
        #expect(call.stack.isEmpty)
        call.captureStack()
        #expect(!call.stack.isEmpty)
        #expect(call.stack.count <= BlockingPendingCall.depth)
        #expect(call.stack.allSatisfy { $0 != 0 })
    }

    // MARK: BlockingPendingRing and the word tables

    @Test func theRingHoldsItsCapacityInOrder() {
        let ring = BlockingPendingRing(capacity: 2)
        #expect(ring.push(BlockingPendingCall(kind: .fileIO, site: 1, fileID: #fileID, line: 1)))
        #expect(ring.push(BlockingPendingCall(kind: .fileIO, site: 2, fileID: #fileID, line: 2)))
        #expect(!ring.push(BlockingPendingCall(kind: .fileIO, site: 3, fileID: #fileID, line: 3)), "full")
        #expect(ring.pop()?.site == 1)
        #expect(ring.push(BlockingPendingCall(kind: .fileIO, site: 4, fileID: #fileID, line: 4)), "wraps around")
        #expect(ring.pop()?.site == 2)
        #expect(ring.pop()?.site == 4)
        #expect(ring.pop() == nil)
    }

    @Test func siteCountersAddReadAndReset() {
        let counters = BlockingSiteCounters(capacity: 3)
        counters.add(site: 2, nanos: 5)
        counters.add(site: 2, nanos: 9)
        counters.add(site: 2, nanos: nil)
        counters.add(site: 0, nanos: 1)
        #expect(counters.read(site: 2) == (count: 3, totalNanos: 14, maxNanos: 9))
        #expect(counters.read(site: 1) == (count: 0, totalNanos: 0, maxNanos: 0))
        counters.add(site: 3, nanos: 7)
        #expect(counters.read(site: 3) == (count: 0, totalNanos: 0, maxNanos: 0), "a site past the table is ignored")
        counters.reset()
        #expect(counters.read(site: 2) == (count: 0, totalNanos: 0, maxNanos: 0))
    }

    @Test func theSharedSiteIndexFindsWhatItInserted() {
        let index = BlockingSharedSiteIndex(capacity: 2)
        let first = BlockingSiteKey(fileID: #fileID, line: 10)
        let second = BlockingSiteKey(fileID: #fileID, line: 11)
        #expect(index.find(first) == nil)
        #expect(index.nextID == 0)
        index.insert(first)
        #expect(index.find(first) == 0)
        index.insert(second)
        #expect(index.find(second) == 1)
        #expect(index.isFull && index.nextID == nil)
        #expect(index.find(BlockingSiteKey(fileID: #fileID, line: 12)) == nil)
    }
    #endif
}
