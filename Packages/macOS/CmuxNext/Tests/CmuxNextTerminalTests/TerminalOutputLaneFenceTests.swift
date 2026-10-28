import CmuxNextCompat
@testable import CmuxNextTerminal
import Dispatch
import Foundation
import GhosttyNextKit
import Testing

/// The output lane is a checked Sendable: its surface is a constant and work on the
/// lane reaches it only while the lane is open, so after ``TerminalOutputLane/close()`` (the fence before
/// `ghostty_surface_free`) nothing queued earlier or later touches the surface. The lane's parse is the
/// test's recorder, so no Ghostty surface is made.
@Suite(.timeLimit(.minutes(1))) struct TerminalOutputLaneFenceTests {
    static let surface = TerminalOutputLaneHangScopeTests.surface

    /// Work queued behind the chunk in flight when the lane closes, and work queued after the close,
    /// never sees the surface; the chunk in flight finishes before close returns.
    @Test func nothingReachesTheSurfaceAfterClose() async {
        let log = SurfaceLog()
        let gate = DispatchSemaphore(value: 0)
        let (started, startedSignal) = AsyncStream.makeStream(of: Void.self)
        // highWater 1: the queued bytes park a capacity waiter, which only the close (or the gate) releases.
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.terminal-fence", highWater: 1) { surface, data in
            if data == Data("first".utf8) {
                startedSignal.yield()
                gate.wait()  // holds the lane inside the first chunk's parse while the close begins
            }
            log.append(String(decoding: data, as: UTF8.self), surface)
        }
        lane.processOutput(Data("first".utf8))
        lane.processOutput(Data("queued".utf8))
        lane.perform { log.append("perform", $0) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()

        let closed = Task.detached { lane.close() }
        // Returns only once the close set its flag: the gate is still shut, so no parse freed capacity.
        await lane.waitForCapacity()
        gate.signal()
        await closed.value
        lane.processOutput(Data("after".utf8))
        lane.perform { log.append("perform after", $0) }
        await lane.drained()

        #expect(log.names == ["first"], "work reached the surface after the lane closed")
        #expect(lane.pendingBytes == 0, "skipped chunks still count as backlog")
    }

    /// An open lane hands every chunk and every `perform` the surface it was made with.
    @Test func anOpenLanePassesItsSurface() async {
        let log = SurfaceLog()
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.terminal-surface") { surface, _ in
            log.append("chunk", surface)
        }
        defer { lane.close() }
        lane.processOutput(Data("chunk".utf8))
        lane.perform { log.append("perform", $0) }
        await lane.drained()

        #expect(log.names == ["chunk", "perform"])
        #expect(log.surfaces == [UInt(bitPattern: Self.surface), UInt(bitPattern: Self.surface)])
    }
}

/// What reached the surface on a lane, in order: a name and the surface's address each time.
nonisolated final class SurfaceLog: Sendable {  // appended to on the output lane
    private let entries = Mutex<[(name: String, surface: UInt)]>([])
    var names: [String] { entries.withLock { $0.map(\.name) } }
    var surfaces: [UInt] { entries.withLock { $0.map(\.surface) } }
    func append(_ name: String, _ surface: ghostty_surface_t) {
        entries.withLock { $0.append((name, UInt(bitPattern: surface))) }
    }
}
