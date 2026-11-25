import CoreGraphics
@testable import CmuxNextBridge
import Testing

/// Pane pictures (ask-b34c6814c9, step B): a card's picture of a tab is captured again only after the tab's
/// content changed; a reopened card draws the kept picture with no capture.
@MainActor
@Suite struct PanePicturesTests {
    /// A schedule with the Rust crate's rules (cmux-pane-pictures `PictureSchedule`), so the glue is tested in a
    /// build whose pinned app FFI predates the crate too.
    @MainActor final class FakeSchedule: PanePictureScheduling {
        let gap: UInt64
        var watched = false, generation: UInt64 = 0, captured: UInt64?, inFlight: UInt64?, lastStart: UInt64?, unavailable: UInt64?
        var events: [PanePictureEvent] = []
        init(gap: UInt64) { self.gap = gap }
        var isCurrent: Bool { captured == generation }
        var dueAt: UInt64? {
            guard watched, inFlight == nil, !isCurrent, unavailable != generation else { return nil }
            return lastStart.map { $0 + gap } ?? 0
        }
        func note(_ event: PanePictureEvent, now: UInt64) -> UInt64? {
            events.append(event)
            switch event {
            case .watched: (watched, unavailable) = (true, nil)
            case .unwatched: watched = false
            case .damaged: generation += 1
            }
            return dueAt
        }
        func takeDue(now: UInt64) -> UInt64? {
            guard let due = dueAt, due <= now else { return nil }
            (inFlight, lastStart) = (generation, now)
            return generation
        }
        func finish(_ generation: UInt64, _ outcome: PanePictureOutcome, now: UInt64) -> UInt64? {
            if inFlight == generation { inFlight = nil }
            switch outcome {
            case .done: captured = max(captured ?? generation, generation)
            case .failed: break
            case .unavailable: unavailable = generation
            }
            return dueAt
        }
    }

    @MainActor final class Harness {
        var clock: UInt64 = 1_000
        var captures = 0
        var slept: [UInt64] = []
        var schedules: [FakeSchedule] = []
        var nothing = false
        lazy var pictures = PanePictures(capacity: 4, makeSchedule: { [unowned self] kind in
            let schedule = FakeSchedule(gap: kind == .terminal ? 200 : 500)
            schedules.append(schedule)
            return schedule
        }, now: { [unowned self] in clock }, sleep: { [unowned self] ms in slept.append(ms); clock += ms })

        func ask(_ tab: String = "t", kind: PanePictures.Kind = .terminal, stamp: UInt64?, size: CGFloat = 320) async -> CGImage? {
            await pictures.picture(tab, kind: kind, stamp: stamp, maxPixelSize: CGSize(width: size, height: size / 2)) {
                captures += 1
                return nothing ? nil : PanePicturesTests.image()
            }
        }
    }

    static func image() -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test func aReopenedCardDrawsTheKeptPictureWithNoCapture() async {
        let harness = Harness()
        let first = await harness.ask(stamp: 7)
        harness.clock += 5_000
        let again = await harness.ask(stamp: 7)
        #expect(first != nil)
        #expect(again === first)
        #expect(harness.captures == 1)
    }

    @Test func outputIsCapturedAgainAfterTheGap() async {
        let harness = Harness()
        _ = await harness.ask(stamp: 1)
        harness.clock += 50
        _ = await harness.ask(stamp: 2)  // changed within the 200 ms gap: waits for the trailing capture
        #expect(harness.captures == 2)
        #expect(harness.slept == [150])
        #expect(harness.schedules.first?.events == [.watched, .damaged])
    }

    @Test func aBurstWithACaptureInFlightDrawsTheKeptPicture() async {
        let harness = Harness()
        let kept = await harness.ask(stamp: 1)
        harness.schedules[0].inFlight = 9  // another card's capture has not ended
        harness.clock += 10
        let shown = await harness.ask(stamp: 2)
        #expect(shown === kept)
        #expect(harness.captures == 1)
    }

    @Test func nothingToPictureIsNotRetriedUntilAChange() async {
        let harness = Harness()
        harness.nothing = true
        #expect(await harness.ask(stamp: 1) == nil)
        harness.clock += 1_000  // the same card asks again (the sidebar's refresh)
        #expect(await harness.ask(stamp: 1) == nil)
        #expect(harness.captures == 1)
        harness.nothing = false
        harness.clock += 1_000
        #expect(await harness.ask(stamp: 2) != nil)
        #expect(harness.captures == 2)
    }

    /// The user, 2026-11-24 (hover cards blank on hibernated tabs): a tab whose capture gives nothing now (hibernated,
    /// its surface gone, its frame purged) keeps drawing its kept picture, never an empty tile.
    @Test func aCaptureThatGivesNothingKeepsTheKeptPicture() async {
        let harness = Harness()
        let kept = await harness.ask(stamp: 1)
        #expect(kept != nil)
        harness.nothing = true
        harness.clock += 1_000
        let shown = await harness.ask(stamp: 2)  // it changed, then hibernated: the new capture has nothing
        #expect(harness.captures == 2)
        #expect(shown === kept)
        harness.clock += 5_000
        #expect(await harness.ask(stamp: 2) === kept, "a card opened again lost the picture")
    }

    @Test func eachSizeAndTabHasItsOwnPicture() async {
        let harness = Harness()
        _ = await harness.ask(stamp: 1, size: 320)
        _ = await harness.ask(stamp: 1, size: 600)
        _ = await harness.ask("u", stamp: 1)
        #expect(harness.captures == 3)
        #expect(harness.pictures.count == 3)
        harness.pictures.forget("t")
        #expect(harness.pictures.count == 1)
    }

    @Test func theLeastRecentlyAskedPictureGoesPastCapacity() async {
        let harness = Harness()
        for tab in ["a", "b", "c", "d", "e"] { _ = await harness.ask(tab, stamp: 1) }
        #expect(harness.pictures.count == 4)
        _ = await harness.ask("a", stamp: 1)
        #expect(harness.captures == 6)  // "a" went first out and is captured again
    }

    @Test func noScheduleCapturesOnEveryAsk() async {
        var captures = 0
        let pictures = PanePictures(makeSchedule: { _ in nil })
        for _ in 0..<3 {
            _ = await pictures.picture("t", kind: .page, stamp: 1, maxPixelSize: CGSize(width: 100, height: 50)) {
                captures += 1
                return PanePicturesTests.image()
            }
        }
        #expect(captures == 3)
    }

    @Test func theRustScheduleKeepsAPictureUntilDamage() {
        guard let schedule = RustPanePictureSchedule(gapMs: RustPanePictureSchedule.terminalGapMs) else {
            #expect(!RustPanePictureSchedule.isLinked)
            return
        }
        #expect(schedule.note(.watched, now: 10) == 0)
        let generation = schedule.takeDue(now: 10)
        #expect(generation == 0)
        #expect(schedule.finish(0, .done, now: 20) == nil)
        #expect(schedule.isCurrent)
        #expect(schedule.note(.damaged, now: 30) == 210)
        #expect(!schedule.isCurrent)
        #expect(schedule.takeDue(now: 100) == nil)
        #expect(schedule.takeDue(now: 210) == 1)
    }
}
