import CmuxNextCompat
@testable import CmuxNextTerminal
import IOSurface
import Testing

/// Evicted terminals' last frames (``TerminalLastFrames``, p07-memory-035): volatile at the warm
/// set's count, no non-volatile saved bytes at rest, every frame dropped at the critical limit, and
/// a memory report that splits volatile bytes from footprint.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct TerminalLastFramesTests {
    /// A 64 x 64 BGRA surface standing in for a terminal's presented drawable.
    private func frame() throws -> TerminalLastFrame {
        let surface = try #require(IOSurface(properties: [
            .width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: 0x4247_5241, // 'BGRA'
        ]))
        return TerminalLastFrame(surface: surface)
    }

    /// Stores `count` frames under keys "t0", "t1", ... and returns them.
    private func store(_ count: Int, in frames: TerminalLastFrames) throws -> [TerminalLastFrame] {
        try (0..<count).map { index in
            let made = try frame()
            frames.keep(made, for: "t\(index)")
            return made
        }
    }

    private func slice(_ limit: MemoryLimit, expired: Bool = false) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: limit) { expired }
    }

    @Test func storedFramesAreVolatileAndCountNoFootprint() throws {
        let frames = TerminalLastFrames(capacity: 8)
        let stored = try store(3, in: frames)
        let bytes = stored.reduce(0) { $0 + $1.bytes }

        #expect(bytes > 0)
        #expect(stored.allSatisfy { $0.isVolatile })
        #expect(frames.nonVolatileBytes == 0)
        #expect(frames.storedBytes == bytes)
        #expect(frames.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: bytes, entries: 3))
    }

    @Test func aFrameAReaderHoldsCountsAsFootprintNotVolatile() throws {
        let frames = TerminalLastFrames(capacity: 8)
        let stored = try store(2, in: frames)
        _ = try #require(stored[0].take())

        #expect(!stored[0].isVolatile)
        #expect(frames.nonVolatileBytes == stored[0].bytes)
        #expect(frames.memoryUsage == MemoryUsage(footprintBytes: stored[0].bytes, volatileBytes: stored[1].bytes, entries: 2))
    }

    @Test func framesStayAtTheWarmSetCountOldestDroppedFirst() throws {
        let frames = TerminalLastFrames(capacity: 2)
        let stored = try store(3, in: frames)

        #expect(frames.count == 2)
        #expect(frames["t0"] == nil)
        #expect(frames.storedBytes == stored[1].bytes + stored[2].bytes)
        #expect(frames.report["dropped"] == 1)

        frames.setCapacity(1)
        #expect(frames.count == 1)
        #expect(frames["t2"] === stored[2])
        #expect(frames.storedBytes == stored[2].bytes)

        frames.setCapacity(0)
        #expect(frames.count == 0)
        #expect(frames.storedBytes == 0)
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

    @Test func atTheCriticalLimitNoNewFrameIsKept() throws {
        let frames = TerminalLastFrames(capacity: 8)
        frames.updateMemoryLimit(.criticalThreshold)
        _ = try store(1, in: frames)
        #expect(frames.count == 0)

        frames.updateMemoryLimit(.default)
        _ = try store(1, in: frames)
        #expect(frames.count == 1)
    }

    @Test func aCriticalReleaseStopsWhenItsSliceExpires() throws {
        let frames = TerminalLastFrames(capacity: 8)
        _ = try store(2, in: frames)

        #expect(frames.releaseMemory(within: slice(.criticalThreshold, expired: true)) == .more)
        #expect(frames.count == 2)
        #expect(frames.releaseMemory(within: slice(.criticalThreshold)) == .done)
        #expect(frames.count == 0)
    }

    @Test func aLimitAboveCriticalReleasesNothing() throws {
        let frames = TerminalLastFrames(capacity: 8)
        _ = try store(3, in: frames)

        #expect(frames.releaseMemory(within: slice(MemoryLimit(percent: 25))) == .done)
        #expect(frames.count == 3)
    }

    @Test func itIsALosslessMemoryOnlyConsumerThatActsAtCriticalOnly() {
        let traits = TerminalLastFrames.memoryTraits
        #expect(traits.retention == .lossless)
        #expect(traits.dataAccess == .none)
        #expect(traits.recreateCost == .cheap)
        #expect(!traits.isManaged) // no warning share: the warm set already shrinks it
    }
}
