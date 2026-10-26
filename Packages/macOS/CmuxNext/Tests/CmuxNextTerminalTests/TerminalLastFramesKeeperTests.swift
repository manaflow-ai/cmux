import CmuxNextCompat
@testable import CmuxNextTerminal
import IOSurface
import Testing

/// Evicted terminals' last frames under the app-wide hidden frame list (p03-rendering-099,
/// `memoryHiddenFrameLRU`): the warm set's capacity bounds nothing, each stored frame is one unlocked
/// frame of the list, a reader locks it, the list's eviction drops it, and a frame that leaves the
/// store on its own leaves the list.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct TerminalLastFramesKeeperTests {
    private func frame() throws -> TerminalLastFrame {
        let surface = try #require(IOSurface(properties: [
            .width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: 0x4247_5241, // 'BGRA'
        ]))
        return TerminalLastFrame(surface: surface)
    }

    private func store(_ key: String, in frames: TerminalLastFrames) throws {
        let made = try frame()
        frames.evict(key, atOnce: false, showsOutput: true) { made }
    }

    @Test func theListNotTheCapacityDecidesWhichFramesStay() throws {
        let keeper = FakeKeeper()
        let frames = TerminalLastFrames(capacity: 2)
        frames.keeper = keeper
        for key in ["t0", "t1", "t2", "t3"] { try store(key, in: frames) }
        #expect(frames.count == 4, "the warm set's capacity still dropped frames")
        #expect(keeper.unlocked == ["t0", "t1", "t2", "t3"].map { TerminalLastFrames.frameID($0) })
        #expect(frames.report["dropped"] == nil)

        keeper.evict(TerminalLastFrames.frameID("t1"))
        #expect(frames["t1"] == nil, "the list's eviction left the frame stored")
        #expect(frames.count == 3)
        #expect(frames.report["dropped"] == 1)
    }

    @Test func aFrameThatLeavesTheStoreLeavesTheList() throws {
        let keeper = FakeKeeper()
        let frames = TerminalLastFrames(capacity: 8)
        frames.keeper = keeper
        try store("t0", in: frames)
        try store("t1", in: frames)
        frames.remove("t0")
        #expect(keeper.unlocked == [TerminalLastFrames.frameID("t1")])
        #expect(keeper.removed.contains(TerminalLastFrames.frameID("t0")))
    }

    @Test func aReaderLocksItsFrameWhileItRenders() async throws {
        let keeper = FakeKeeper()
        let frames = TerminalLastFrames(capacity: 8)
        frames.keeper = keeper
        try store("t0", in: frames)
        let held = try #require(frames["t0"])
        let id = TerminalLastFrames.frameID("t0")

        let reader = Task { await held.snapshot(maxPixelSize: 32) }
        await Task.yield() // the reader runs up to its off-main render, holding the pages
        #expect(keeper.locks[id] == 1, "a read frame was not locked")
        _ = await reader.value
        #expect(keeper.locks[id] == nil, "the frame stayed locked after the read")
        #expect(keeper.unlocked == [id])
    }

    @Test func withoutAKeeperTheCapacityStillBounds() throws {
        let frames = TerminalLastFrames(capacity: 2)
        for key in ["t0", "t1", "t2"] { try store(key, in: frames) }
        #expect(frames.count == 2)
        #expect(frames["t0"] == nil)
    }
}

/// A list that records what the store tells it and evicts when the test says.
@MainActor
private final class FakeKeeper: HiddenFrameKeeper {
    private(set) var unlocked: [HiddenFrameID] = []
    private(set) var locks: [HiddenFrameID: Int] = [:]
    private(set) var removed: [HiddenFrameID] = []
    private var evictions: [HiddenFrameID: @MainActor () -> Void] = [:]

    func add(_ id: HiddenFrameID, locked: Bool, evict: @escaping @MainActor () -> Void) {
        forget(id)
        evictions[id] = evict
        if locked { locks[id] = 1 } else { unlocked.append(id) }
    }

    func remove(_ id: HiddenFrameID) {
        removed.append(id)
        forget(id)
    }

    func lock(_ id: HiddenFrameID) {
        unlocked.removeAll { $0 == id }
        locks[id, default: 0] += 1
    }

    func unlock(_ id: HiddenFrameID) {
        guard let count = locks[id] else { return }
        if count > 1 {
            locks[id] = count - 1
        } else {
            locks[id] = nil
            unlocked.append(id)
        }
    }

    func evict(_ id: HiddenFrameID) {
        guard let evict = evictions[id] else { return }
        forget(id)
        evict()
    }

    private func forget(_ id: HiddenFrameID) {
        unlocked.removeAll { $0 == id }
        locks[id] = nil
        evictions[id] = nil
    }
}
