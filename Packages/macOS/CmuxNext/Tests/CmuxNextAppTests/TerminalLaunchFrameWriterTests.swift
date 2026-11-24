import AppKit
import CmuxNextCompat
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// FILES QUEUE (Leo's NIGHTLY, 2026-11-21): the serial `files.bestEffort` lane was busy 66% of a 3 s sample, all in the
/// launch frame keeper's PNG encode, and every switch back to a terminal encoded the same pixels again. Leo: "dont
/// label things and immediately dismjss them / measure then solve". The keeper's writes are deltas now
/// (``TerminalLaunchFrameWriter``); these pin it: an unchanged frame is never encoded again, a terminal shown again
/// with its old pixels gets its file back by a rename, saves of one terminal coalesce to the latest, and a write
/// encoded before a hide lands nothing.
@MainActor @Suite(.serialized) struct TerminalLaunchFrameWriterTests {
    /// The callbacks a writer made, by key, and a gate that holds its CPU lane.
    nonisolated final class Probe: Sendable {
        let written = Mutex(0)
        let gate = DispatchSemaphore(value: 0)
        let holding = Mutex(false)
        var count: Int { written.withLock { $0 } }
        var callback: @Sendable (String) -> Void { { [self] _ in written.withLock { $0 += 1 } } }
    }

    let directory = FileManager.default.temporaryDirectory.appending(path: "frame-writer-\(UUID().uuidString)")
    /// One CPU lane slot, so a held job holds every encode behind it.
    let work = BackgroundWork(cpuWidth: 1, label: "test.terminal-launch-frame-writer")
    let probe = Probe()

    func writer() -> TerminalLaunchFrameWriter {
        TerminalLaunchFrameWriter(directory: directory, work: work, stillWanted: { true })
    }

    /// A see-through 64 x 32 frame (a PNG, as a terminal on a see-through window); each `shade` below 64 draws a bar of
    /// its own width, so two shades never give the same pixels (half-alpha colors of near shades premultiply alike).
    static func frame(_ shade: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: CGFloat(shade % 256) / 255, green: 0.2, blue: 0.4, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 16))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 20, width: shade % 64 + 1, height: 4))
        return try #require(context.makeImage())
    }

    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// Waits until the writer made `count` callbacks (each save that was not coalesced, park and forget makes one).
    func written(_ count: Int) async throws {
        let done = try await TerminalLaunchFrameKeeperTests.eventually(20) { probe.count >= count }
        try #require(done, "the writer made \(probe.count) of \(count) callbacks")
    }

    /// Holds the CPU lane until ``release()``: saves posted meanwhile queue behind it.
    func hold() async throws {
        let probe = probe
        work.post(.userVisible, mayBlock: .cpu) {
            probe.holding.withLock { $0 = true }
            _ = probe.gate.wait(timeout: .now() + 30) // test: bounded hold of the CPU lane
        }
        let held = try await TerminalLaunchFrameKeeperTests.eventually(10) { probe.holding.withLock { $0 } }
        try #require(held, "the CPU lane never ran the hold")
    }

    func release() { probe.gate.signal() }

    /// Waits until every job posted so far ran on both lanes: a marker after them on the CPU lane (one slot, in order
    /// within a priority) posts one after them on the files lane (serial per priority).
    func drained() async throws {
        let work = work
        let marker = Probe()
        work.post(.bestEffort, mayBlock: .cpu) {
            work.post(.bestEffort, mayBlock: .files) { marker.written.withLock { $0 = 1 } }
        }
        let ran = try await TerminalLaunchFrameKeeperTests.eventually(20) { marker.count == 1 }
        try #require(ran, "the lanes never drained")
    }

    @Test func anUnchangedFrameIsNeverEncodedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = writer()
        writer.save("tab_same", frame: try Self.frame(1), scale: 2, keeping: nil, written: probe.callback)
        try await written(1)
        writer.save("tab_same", frame: try Self.frame(1), scale: 2, keeping: nil, written: probe.callback)
        try await written(2)
        #expect(writer.stats.encodes == 1, "an unchanged frame was encoded \(writer.stats.encodes) times: the keeper re-encodes output it already wrote")
        #expect(writer.stats.unchanged == 1)
        #expect(files() == ["tab_same@2x.jpg"])
        // New pixels are encoded.
        writer.save("tab_same", frame: try Self.frame(2), scale: 2, keeping: nil, written: probe.callback)
        try await written(3)
        #expect(writer.stats.encodes == 2, "a changed frame was not encoded")
    }

    @Test func aTerminalShownAgainWithTheSamePixelsGetsItsFileBackWithNoEncode() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = writer()
        writer.save("tab_switch", frame: try Self.frame(3), scale: 2, keeping: nil, written: probe.callback)
        try await written(1)
        let bytes = try Data(contentsOf: directory.appending(path: "tab_switch@2x.jpg"))
        // Switched away: no launch reads its frame now (it is not on screen at a kill).
        writer.park("tab_switch", written: probe.callback)
        try await written(2)
        #expect(files() == ["tab_switch@2x.jpg.parked"], "a hidden terminal's frame is still read at launch: \(files())")
        #expect(TerminalLaunchFrames.owner(of: "tab_switch@2x.jpg.parked") == nil, "a parked frame counts as a saved one")
        // Switched back, nothing new printed: the same pixels.
        writer.save("tab_switch", frame: try Self.frame(3), scale: 2, keeping: nil, written: probe.callback)
        try await written(3)
        #expect(writer.stats.encodes == 1, "a terminal shown again with the same pixels was encoded again")
        #expect(writer.stats.restored == 1)
        #expect(files() == ["tab_switch@2x.jpg"])
        #expect(try Data(contentsOf: directory.appending(path: "tab_switch@2x.jpg")) == bytes)
        // Switched away and back with new output: encoded, and the parked file is gone with the old frame.
        writer.park("tab_switch", written: probe.callback)
        try await written(4)
        writer.save("tab_switch", frame: try Self.frame(4), scale: 2, keeping: nil, written: probe.callback)
        try await written(5)
        #expect(writer.stats.encodes == 2)
        #expect(files() == ["tab_switch@2x.jpg"], "the old frame's parked file outlived the new frame: \(files())")
    }

    @Test func savesOfOneTerminalWhileTheLaneIsBusyCoalesceToTheLatest() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = writer()
        try await hold()
        for shade in 0..<50 {
            writer.save("tab_busy", frame: try Self.frame(shade), scale: 1, keeping: nil, written: probe.callback)
        }
        release()
        try await written(1)
        #expect(writer.stats.encodes == 1, "\(writer.stats.encodes) encodes for 50 saves queued behind a busy lane: one per terminal is enough")
        #expect(writer.stats.coalesced == 49)
        // The one written is the latest: saving it again writes nothing.
        writer.save("tab_busy", frame: try Self.frame(49), scale: 1, keeping: nil, written: probe.callback)
        try await written(2)
        #expect(writer.stats.unchanged == 1, "the frame on disk is not the latest save's")
    }

    @Test func aWriteEncodedBeforeAHideOrCloseLandsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = writer()
        try await hold()
        writer.save("tab_hidden", frame: try Self.frame(7), scale: 2, keeping: nil, written: probe.callback)
        writer.park("tab_hidden", written: probe.callback)
        writer.save("tab_closed", frame: try Self.frame(8), scale: 2, keeping: nil, written: probe.callback)
        writer.forget("tab_closed", written: probe.callback)
        release()
        try await written(2) // the park and the forget; the saves drop
        try await drained()
        #expect(files().isEmpty, "a frame saved before its terminal hid or closed landed after: \(files())")
        #expect(writer.stats.encodes == 0)
    }

    /// The launch read takes only `<key>@<scale>x.jpg`: a parked file of a closed terminal goes with its frames, and the
    /// keeper's prune of terminals this run does not show takes their parked files too.
    @Test func closedAndUnshownTerminalsLoseTheirParkedFiles() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = writer()
        for key in ["tab_a", "tab_b", "tab_c"] {
            writer.save(key, frame: try Self.frame(9), scale: 2, keeping: nil, written: probe.callback)
        }
        try await written(3)
        writer.park("tab_a", written: probe.callback)
        writer.park("tab_b", written: probe.callback)
        try await written(5)
        writer.forget("tab_a", written: probe.callback)
        try await written(6)
        #expect(files() == ["tab_b@2x.jpg.parked", "tab_c@2x.jpg"])
        // tab_b is not shown by this run any more: the next save's prune takes its parked file.
        writer.save("tab_c", frame: try Self.frame(10), scale: 2, keeping: ["tab_c"], written: probe.callback)
        try await written(7)
        #expect(files() == ["tab_c@2x.jpg"], "a parked file of a terminal this run does not show stayed: \(files())")
    }
}
