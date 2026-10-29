import CmuxNextCompat
@testable import CmuxNextTerminal
import IOSurface
import Testing

/// Evicted terminals' last frames (``TerminalLastFrames``): volatile at the warm
/// set's count, no non-volatile saved bytes at rest (read from the IOSurfaces themselves), every
/// frame dropped at the critical limit, and a memory report that splits volatile bytes from
/// footprint.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct TerminalLastFramesTests {
    /// A stored frame and the surface the test made for it, to read its real purgeable state.
    struct Stored {
        let frame: TerminalLastFrame
        let surface: IOSurface
    }

    /// A 64 x 64 BGRA surface standing in for a terminal's presented drawable.
    private func frame() throws -> Stored {
        let surface = try #require(IOSurface(properties: [
            .width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: 0x4247_5241, // 'BGRA'
        ]))
        return Stored(frame: TerminalLastFrame(surface: surface), surface: surface)
    }

    /// Evicts `count` terminals that show output under keys "t0", "t1", ... and returns their frames.
    private func store(_ count: Int, in frames: TerminalLastFrames) throws -> [Stored] {
        try (0..<count).map { index in
            let made = try frame()
            frames.evict("t\(index)", atOnce: false, showsOutput: true) { made.frame }
            return made
        }
    }

    /// The surface's purgeable state as the kernel keeps it (kIOSurfacePurgeableKeepCurrent reads it
    /// and changes nothing).
    private func purgeableState(_ surface: IOSurface) -> UInt32 {
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(surface, 3, &old)
        return old
    }

    private func slice(_ limit: MemoryLimit, expired: Bool = false) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: limit) { expired }
    }

    @Test func storedFramesAreVolatileAndCountNoFootprint() throws {
        let frames = TerminalLastFrames(capacity: 8)
        let stored = try store(3, in: frames)
        let bytes = stored.reduce(0) { $0 + $1.frame.bytes }

        #expect(bytes > 0)
        #expect(stored.allSatisfy { purgeableState($0.surface) == IOSurface.purgeableVolatile })
        #expect(stored.allSatisfy { $0.frame.isVolatile })
        #expect(frames.nonVolatileBytes == 0)
        #expect(frames.storedBytes == bytes)
        #expect(frames.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: bytes, entries: 3))
    }

    /// The one reader of a stored frame is the hover card's snapshot: its pages count as footprint
    /// while it renders, and are volatile again, in the kernel too, when it ends.
    @Test func aSnapshotCountsItsFrameAsFootprintOnlyWhileItRenders() async throws {
        let frames = TerminalLastFrames(capacity: 8)
        let stored = try store(2, in: frames)
        let held = stored[0], other = stored[1]

        let reader = Task { await held.frame.snapshot(maxPixelSize: 32) }
        await Task.yield() // the reader runs up to its off-main render, holding the pages
        #expect(!held.frame.isVolatile)
        #expect(purgeableState(held.surface) == IOSurface.purgeableNonVolatile)
        #expect(frames.memoryUsage == MemoryUsage(footprintBytes: held.frame.bytes, volatileBytes: other.frame.bytes, entries: 2))

        _ = await reader.value
        #expect(held.frame.isVolatile)
        #expect(purgeableState(held.surface) == IOSurface.purgeableVolatile)
        #expect(frames.nonVolatileBytes == 0)
        #expect(frames.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: held.frame.bytes + other.frame.bytes, entries: 2))
    }

    /// A frame that leaves the store while a snapshot renders (shown again, or dropped) leaves the
    /// counters at once; the snapshot's end does not count it again.
    @Test func aFrameThatLeavesWhileReadLeavesTheCounters() async throws {
        let frames = TerminalLastFrames(capacity: 8)
        let stored = try store(1, in: frames)

        let reader = Task { await stored[0].frame.snapshot(maxPixelSize: 32) }
        await Task.yield()
        #expect(frames.nonVolatileBytes == stored[0].frame.bytes)
        frames.remove("t0")
        #expect(frames.nonVolatileBytes == 0)
        #expect(frames.storedBytes == 0)

        _ = await reader.value
        #expect(frames.nonVolatileBytes == 0)
        #expect(purgeableState(stored[0].surface) == IOSurface.purgeableVolatile)
    }

    /// A reader that finds the pages purged gets nothing, leaves them volatile and takes the frame
    /// out of the store, so its slot and bytes count only live frames.
    @Test func aPurgedFrameLeavesTheStoreAndStaysVolatile() async throws {
        let frames = TerminalLastFrames(capacity: 8)
        let stored = try store(2, in: frames)
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(stored[0].surface, IOSurface.purgeableEmpty, &old) // the kernel takes the pages

        let image = await stored[0].frame.snapshot(maxPixelSize: 32)
        #expect(image == nil)
        #expect(stored[0].frame.isPurged)
        #expect(purgeableState(stored[0].surface) == IOSurface.purgeableVolatile)
        #expect(frames["t0"] == nil)
        #expect(frames.count == 1)
        #expect(frames.storedBytes == stored[1].frame.bytes)
        #expect(frames.nonVolatileBytes == 0)
        #expect(frames.report["purged"] == 1)
    }

    /// The bound applies to the frames kept from now on: a smaller one frees nothing at once, and
    /// the next frame kept drops the oldest past it.
    @Test func framesStayAtTheWarmSetCountOldestDroppedFirst() throws {
        let frames = TerminalLastFrames(capacity: 2)
        let stored = try store(3, in: frames)

        #expect(frames.count == 2)
        #expect(frames["t0"] == nil)
        #expect(frames.storedBytes == stored[1].frame.bytes + stored[2].frame.bytes)
        #expect(frames.report["dropped"] == 1)

        frames.setCapacity(1)
        #expect(frames.count == 2, "a smaller bound dropped frames in its turn")

        let next = try frame()
        frames.evict("t3", atOnce: false, showsOutput: true) { next.frame }
        #expect(frames.count == 1)
        #expect(frames["t3"] === next.frame)
        #expect(frames.storedBytes == next.frame.bytes)
        #expect(frames.report["dropped"] == 3)
    }

    @Test func theCriticalLimitDropsEveryFrame() throws {
        let frames = TerminalLastFrames(capacity: 8)
        _ = try store(3, in: frames)

        frames.updateMemoryLimit(.criticalThreshold)
        #expect(frames.count == 3) // the limit frees nothing
        #expect(frames.releaseMemory(within: slice(.criticalThreshold)) == .done)

        #expect(frames.count == 0)
        #expect(frames.storedBytes == 0)
        #expect(frames.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: 0, entries: 0))
        #expect(frames.report["dropped_critical"] == 3)
    }

    /// The eviction's own decision: at the critical limit, at capacity 0 or in a pressure drop it
    /// keeps no frame and never reads one.
    @Test func anEvictionKeepsNoFrameAtTheCriticalLimit() throws {
        let frames = TerminalLastFrames(capacity: 8)
        let made = try frame()
        var read = 0
        frames.updateMemoryLimit(.criticalThreshold)
        frames.evict("t0", atOnce: false, showsOutput: true) { read += 1; return made.frame }
        #expect(read == 0)
        #expect(frames.count == 0)
        #expect(frames.report["evicted_at_once"] == 1)
        #expect(frames.report["kept"] == nil)

        frames.updateMemoryLimit(.default)
        frames.evict("t0", atOnce: true, showsOutput: true) { read += 1; return made.frame }
        #expect(frames.report["evicted_at_once"] == 2)
        frames.evict("t0", atOnce: false, showsOutput: true) { read += 1; return made.frame }
        #expect(read == 1)
        #expect(frames.count == 1)
        #expect(frames.report["kept"] == 1)
    }

    @Test func anEvictionAtCapacityZeroOrWithoutOutputKeepsNoFrame() throws {
        let empty = TerminalLastFrames(capacity: 0)
        let made = try frame()
        empty.evict("t0", atOnce: false, showsOutput: true) { made.frame }
        #expect(empty.count == 0)
        #expect(empty.report["evicted_at_once"] == 1)

        let frames = TerminalLastFrames(capacity: 8)
        frames.evict("t0", atOnce: false, showsOutput: false) { made.frame }
        frames.evict("t1", atOnce: false, showsOutput: true) { nil }
        #expect(frames.count == 0)
        #expect(frames.report["evicted_no_output"] == 1)
        #expect(frames.report["evicted_no_frame"] == 1)
    }

    @Test func aCriticalReleaseStopsWhenItsSliceExpires() throws {
        let frames = TerminalLastFrames(capacity: 8)
        _ = try store(2, in: frames)

        #expect(frames.releaseMemory(within: slice(.criticalThreshold, expired: true)) == .more)
        #expect(frames.count == 2)
        #expect(frames.releaseMemory(within: slice(.criticalThreshold)) == .done)
        #expect(frames.count == 0)
    }

    @Test func aLimitAboveCriticalKeepsTheWarmSetsCount() throws {
        let frames = TerminalLastFrames(capacity: 8)
        _ = try store(3, in: frames)

        #expect(frames.releaseMemory(within: slice(MemoryLimit(percent: 25))) == .done)
        #expect(frames.count == 3)

        frames.setCapacity(1)
        #expect(frames.releaseMemory(within: slice(MemoryLimit(percent: 25))) == .done)
        #expect(frames.count == 1)
        #expect(frames["t2"] != nil)
        #expect(frames.report["dropped_critical"] == nil)
    }

    @Test func itIsALosslessMemoryOnlyConsumerThatActsAtCriticalOnly() {
        let traits = TerminalLastFrames.memoryTraits
        #expect(traits.retention == .lossless)
        #expect(traits.dataAccess == .none)
        #expect(traits.recreateCost == .cheap)
        #expect(!traits.isManaged) // no warning share: the warm set already bounds it
    }
}
