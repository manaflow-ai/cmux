@testable import CmuxNextTerminal
import IOSurface
import Testing

/// SWITCH FRAMES (STATUS 7963, W1 HEAVY on cmux23, feat 25c84f33c5a): a switch to a 12-pane workspace showed empty
/// panes for 24-31 refreshes (about 220 ms). The warm set (8 terminals) evicts the last workspace's 12 terminals at
/// every switch, and the last-frame store kept 29 frames: 8 plus 1/32 of a 16 GB Mac at 24 MiB a frame, a full-window
/// frame. A pane of a 3 x 4 grid is a twelfth of that, so the store dropped frames it had room for, and no revealed
/// pane of the last workspaces had its frame (last_frames.dropped +12 a switch, shown never grew). The store counts
/// each frame's own bytes: every pane of the last workspaces that fit in the memory bound keeps its frame.
@MainActor @Suite struct TerminalLastFramesBudgetTests {
    static let physical: UInt64 = 16 << 30

    /// One pane's drawable: a 3 x 4 grid of a 1728 x 945 point window on a 2x display.
    static func paneFrame() throws -> TerminalLastFrame {
        let surface = try #require(IOSurface(properties: [
            .width: 1152, .height: 472, .bytesPerElement: 4, .pixelFormat: 0x4247_5241, // 'BGRA'
        ]))
        return TerminalLastFrame(surface: surface, showsOutput: true)
    }

    @Test func everyPaneOfTheLastWorkspacesKeepsItsFrame() throws {
        var frames = TerminalLastFrames()
        // 9 workspaces of 12 panes, each evicted in turn as the next one shows (W1 HEAVY's Cmd-1..9).
        for workspace in 1...9 {
            for pane in 1...12 { frames.keep(try Self.paneFrame(), for: "ws\(workspace)-p\(pane)", warm: 8, physicalBytes: Self.physical) }
        }
        let missing = (1...9).flatMap { workspace in (1...12).map { "ws\(workspace)-p\($0)" } }.filter { frames[$0] == nil }
        #expect(missing.isEmpty, "\(missing.count) of 108 pane frames were dropped (stored \(frames.count)): \(missing.prefix(12))")
    }

    @Test func fullWindowFramesStillStopAtTheMemoryBound() throws {
        var frames = TerminalLastFrames()
        for k in 1...200 {
            let surface = try #require(IOSurface(properties: [
                .width: 3456, .height: 1890, .bytesPerElement: 4, .pixelFormat: 0x4247_5241,
            ]))
            frames.keep(TerminalLastFrame(surface: surface, showsOutput: true), for: "t\(k)", warm: 8, physicalBytes: Self.physical)
        }
        // 1/32 of 16 GB is 512 MiB; a 3456 x 1890 BGRA frame is about 26 MB: about 20 of them, plus the warm 8 at most.
        #expect(frames.count <= 8 + 21, "a 16 GB Mac kept \(frames.count) full-window frames")
        #expect(frames.storedBytes <= TerminalLastFrames.byteBudget(physicalBytes: Self.physical),
                "\(frames.storedBytes >> 20) MiB kept past the \(TerminalLastFrames.byteBudget(physicalBytes: Self.physical) >> 20) MiB bound")
        #expect(frames["t200"] != nil, "the newest frame was dropped")
    }

    /// Frames larger than the whole budget: the warm set's count still keeps its frames (the floor wins).
    @Test func theWarmSetsFramesStayWhenTheyAloneFillTheBudget() throws {
        var frames = TerminalLastFrames()
        for k in 1...20 {
            let surface = try #require(IOSurface(properties: [
                .width: 3456, .height: 1890, .bytesPerElement: 4, .pixelFormat: 0x4247_5241,
            ]))
            frames.keep(TerminalLastFrame(surface: surface, showsOutput: true), for: "t\(k)", warm: 8, physicalBytes: 64 << 20)
        }
        #expect(frames.count == 8, "a 2 MiB budget kept \(frames.count) frames (want the warm set's 8)")
        #expect((13...20).allSatisfy { frames["t\($0)"] != nil }, "the 8 newest frames are not the ones kept")
    }
}
