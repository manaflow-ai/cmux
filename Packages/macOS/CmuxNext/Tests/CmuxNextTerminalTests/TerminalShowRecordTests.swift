#if DEBUG || CMUX_BENCH_HOOKS
import CoreGraphics
import CmuxNextCompat
@testable import CmuxNextTerminal
import QuartzCore
import Testing

/// A terminal shown again (its window uncovered, its pause ended) must draw its current content within
/// one frame. The journeys could only poll `debug.surfaces` (a main-actor read that waited 217-232 ms
/// behind Close Window on v2.2.4-opt), so "within one frame" was never measured. The show record keeps,
/// per surface, when its pause ended (main) and when its layer next got a frame (the `setContents:`
/// hook, any thread): record only, read by `debug.surfaces`.
/// skip-owner: PL-ghostty; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
@MainActor @Suite(.serialized, .enabled(if: TypingFrameProbe.hooksEveryLayer, "renderer-owned frames set no layer contents"))
struct TerminalShowRecordTests {
    nonisolated final class ShownLayer: CALayer {}
    /// Its own class: the hook is installed once per layer class, with one gate (TypingFrameProbe.installed).
    nonisolated final class ClearedLayer: CALayer {}

    @Test func theFirstFrameAfterTheUnpauseIsRecordedOnce() {
        let gate = TerminalContentsGate()
        let clock = TestClock(1_000)
        let record = TerminalShowRecord(gate: gate, now: { clock.now })
        record.contentsSet()
        #expect(record.timing == nil, "a frame before any unpause is no show")
        clock.now = 2_000
        record.unpaused()
        #expect(record.timing == TerminalShowTiming(unpausedNanos: 2_000, firstFrameNanos: nil))
        #expect(gate.showsWaiting && !gate.isOpen, "a waiting show opens only its own count, never the echo path")
        clock.now = 2_500
        record.contentsSet()
        clock.now = 9_000
        record.contentsSet()
        #expect(record.timing == TerminalShowTiming(unpausedNanos: 2_000, firstFrameNanos: 2_500))
        #expect(record.timing?.unpauseToFrameMilliseconds == 0.0005)
        #expect(!gate.showsWaiting, "no record waits after its frame: the hook looks nothing up")
    }

    @Test func aSecondUnpauseWaitsForItsOwnFrame() {
        let gate = TerminalContentsGate()
        let clock = TestClock(10)
        let record = TerminalShowRecord(gate: gate, now: { clock.now })
        record.unpaused()
        clock.now = 20
        record.contentsSet()
        clock.now = 30
        record.unpaused()
        #expect(record.timing == TerminalShowTiming(unpausedNanos: 30, firstFrameNanos: nil))
        clock.now = 45
        record.contentsSet()
        #expect(record.timing == TerminalShowTiming(unpausedNanos: 30, firstFrameNanos: 45))
    }

    @Test func theLayersFrameHookFeedsItsRecord() throws {
        let layer = ShownLayer()
        let gate = TerminalContentsGate()
        TypingFrameProbe.install(on: layer, gate: gate)
        let clock = TestClock(100)
        let record = TerminalShowRecord(gate: gate, now: { clock.now })
        record.attach(to: layer)
        record.unpaused()
        clock.now = 160
        layer.contents = try #require(Self.image())
        #expect(record.timing?.firstFrameNanos == 160)
    }

    /// The record's clock, set by the test (read from the record's own calls on this thread).
    nonisolated final class TestClock: Sendable {
        private let value: Atomic<UInt64>
        init(_ start: UInt64) { value = Atomic(start) }
        var now: UInt64 {
            get { value.load(ordering: .relaxed) }
            set { value.store(newValue, ordering: .relaxed) }
        }
    }

    /// Clearing the layer (a purged held frame: `contents = nil`) is no frame: the pane shows nothing yet.
    @Test func clearedContentsAreNoFrame() throws {
        let layer = ClearedLayer()
        let gate = TerminalContentsGate()
        TypingFrameProbe.install(on: layer, gate: gate)
        let clock = TestClock(100)
        let record = TerminalShowRecord(gate: gate, now: { clock.now })
        record.attach(to: layer)
        record.unpaused()
        clock.now = 120
        layer.contents = nil
        #expect(record.timing?.firstFrameNanos == nil, "a purge counted as the show's frame")
        clock.now = 190
        layer.contents = try #require(Self.image())
        #expect(record.timing?.firstFrameNanos == 190)
    }

    private static func image() -> CGImage? {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return context.makeImage()
    }
}
#endif
