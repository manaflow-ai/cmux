#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextInput
import CmuxNextInputCore
import Foundation
import Testing
import WebKit

/// WebPageInputTiming (p04-input-099): a recorded page report closes its WebKit page slot with a page-estimated
/// presented stage; unmatched reports and slots are counted and dropped; the page script posts numbers only.
@MainActor
struct WebPageInputTimingTests {
    /// The tracker's side: the open-slot table and the slots it finished.
    final class FakeSlots: InputSlotFinishing {
        let table = InputLatencySlotTable()
        var finished: [InputLatencySlot] = []

        func finish(_ token: InputLatencyToken) {
            if let slot = table.close(token) { finished.append(slot) }
        }
    }

    /// Presents a commit 1 ms after it ends.
    final class FakePresentation: InputPresentationEstimating {
        static let renderServerNanos: UInt64 = 1_000_000
        var asked: [UInt64] = []

        func holdLinkForInput(in window: NSWindow?) {}

        func presentedNanos(commitEndNanos: UInt64, in window: NSWindow?) -> UInt64 {
            asked.append(commitEndNanos)
            return commitEndNanos + Self.renderServerNanos
        }
    }

    /// A WebKit page slot the commit handed over.
    final class Harness {
        let slots = FakeSlots()
        let presentation = FakePresentation()
        var clock: UInt64 = 10_000_000_000
        private(set) var timing: WebPageInputTiming!

        init() {
            timing = WebPageInputTiming(slots: slots, presentation: presentation, now: { [unowned self] in clock })
        }

        /// Opens a slot generated at `generated` and offers it to the timing at its commit.
        func open(_ kind: InputEventKind = .keyPress, target: InputTarget = .webkitPage,
                  generated: UInt64) throws -> (token: InputLatencyToken, taken: Bool) {
            let token = try #require(slots.table.begin(kind: kind, target: target, entrypoint: .person,
                                                       generated: generated))
            slots.table.mark(token, .mainCommit, at: generated + 2_000_000)
            return (token, timing.takeOver(token, kind: kind, target: target, generatedNanos: generated))
        }
    }

    /// The page document: `performance.now()` 0 is uptime 5 s, so page 5000 ms is uptime 10 s.
    static let origin = 1_761_480_000_123.5
    static let pageZeroNanos: UInt64 = 5_000_000_000

    /// A message body as WebKit hands it over: the page's JSON array, decoded to NSNumbers.
    static func recorded(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    static func report(kind: Int, eventMs: Double, renderedMs: Double) throws -> Any {
        try recorded("[\(kind),\(origin),\(eventMs),\(renderedMs)]")
    }

    @Test("A recorded key report closes its slot with contentSubmitted, presented and source pageEstimated")
    func recordedReportClosesSlot() throws {
        let harness = Harness()
        let generated: UInt64 = 10_000_000_000
        let opened = try harness.open(generated: generated)
        #expect(opened.taken)
        #expect(harness.slots.finished.isEmpty, "the slot waits for the page")

        // Rendered at page 5012.5 ms (uptime 10.0125 s), delivered with no delay.
        let body = try Self.recorded("[0,\(Self.origin),5000,5012.5]")
        harness.timing.receive(body, in: nil, receivedNanos: 10_012_500_000)

        let slot = try #require(harness.slots.finished.first)
        #expect(harness.slots.finished.count == 1)
        #expect(slot.kind == .keyPress)
        #expect(slot.target == .webkitPage)
        #expect(slot.presentationSource == .pageEstimated)
        #expect(slot.generated == generated)
        #expect(slot.mainCommit == generated + 2_000_000)
        #expect(slot.contentSubmitted == 10_012_500_000)
        #expect(slot.presented == 10_012_500_000 + FakePresentation.renderServerNanos)
        #expect(harness.presentation.asked == [10_012_500_000])
        #expect(harness.timing.counts.matched == 1)
        #expect(harness.timing.waitingCount == 0)
    }

    @Test("The page clock offset keeps the smallest delivery sample of its document")
    func clockOffsetTakesTheMinimumSample() throws {
        let harness = Harness()
        // The first report arrives 3 ms late, so its event maps 3 ms after its slot (still matched).
        _ = try harness.open(generated: 10_000_000_000)
        harness.timing.receive(try Self.report(kind: 0, eventMs: 5000, renderedMs: 5010), in: nil,
                               receivedNanos: 10_013_000_000)
        #expect(harness.slots.finished.last?.contentSubmitted == 10_013_000_000)

        // The second arrives on time: the offset drops to the real one.
        _ = try harness.open(generated: 10_100_000_000)
        harness.timing.receive(try Self.report(kind: 0, eventMs: 5100, renderedMs: 5108), in: nil,
                               receivedNanos: 10_108_000_000)
        #expect(harness.slots.finished.last?.contentSubmitted == 10_108_000_000)

        // A third, 5 ms late, still maps with the on-time offset.
        _ = try harness.open(generated: 10_200_000_000)
        harness.timing.receive(try Self.report(kind: 0, eventMs: 5200, renderedMs: 5209), in: nil,
                               receivedNanos: 10_214_000_000)
        #expect(harness.slots.finished.last?.contentSubmitted == 10_209_000_000)
        #expect(harness.timing.counts.matched == 3)
    }

    @Test("Only WebKit page slots of a reported kind are taken")
    func takesOnlyWebKitPageSlots() throws {
        let harness = Harness()
        #expect(try harness.open(target: .terminal, generated: 10_000_000_000).taken == false)
        #expect(try harness.open(target: .chromiumPage, generated: 10_000_000_000).taken == false)
        #expect(try harness.open(.keyRelease, generated: 10_000_000_000).taken == false)
        #expect(try harness.open(.pointerMove, generated: 10_000_000_000).taken == false)
        #expect(try harness.open(.mousePress, generated: 10_000_000_000).taken)
        #expect(try harness.open(.scrollFirstUpdate, generated: 10_000_000_000).taken)
        #expect(harness.timing.waitingCount == 2)
    }

    @Test("A report with no waiting slot of its kind is counted and dropped")
    func unmatchedReportIsCountedAndDropped() throws {
        let harness = Harness()
        harness.timing.receive(try Self.report(kind: 0, eventMs: 5000, renderedMs: 5010), in: nil,
                               receivedNanos: 10_010_000_000)
        #expect(harness.timing.counts.unmatched == 1)

        // A waiting key slot is not matched by a wheel report, nor by a key report 500 ms away.
        _ = try harness.open(generated: 11_000_000_000)
        harness.timing.receive(try Self.report(kind: 3, eventMs: 6000, renderedMs: 6010), in: nil,
                               receivedNanos: 11_010_000_000)
        harness.timing.receive(try Self.report(kind: 0, eventMs: 6500, renderedMs: 6510), in: nil,
                               receivedNanos: 11_510_000_000)
        #expect(harness.timing.counts.unmatched == 3)
        #expect(harness.slots.finished.isEmpty)
        #expect(harness.timing.waitingCount == 1)
    }

    @Test("Reports come in event order: an older slot of the matched kind closes as missed")
    func olderSlotOfMatchedKindIsMissed() throws {
        let harness = Harness()
        let first = try harness.open(generated: 10_000_000_000)
        let click = try harness.open(.mousePress, generated: 10_010_000_000)
        let second = try harness.open(generated: 10_030_000_000)
        #expect(first.taken && click.taken && second.taken)

        harness.timing.receive(try Self.report(kind: 0, eventMs: 5030, renderedMs: 5040), in: nil,
                               receivedNanos: 10_040_000_000)

        #expect(harness.slots.finished.count == 2)
        let missed = try #require(harness.slots.finished.first)
        #expect(missed.generated == 10_000_000_000)
        #expect(!missed.reached(.presented), "readers drop a slot with presented skipped")
        #expect(missed.presentationSource == .estimatedVsync)
        let matched = try #require(harness.slots.finished.last)
        #expect(matched.generated == 10_030_000_000)
        #expect(matched.presentationSource == .pageEstimated)
        #expect(harness.timing.counts.missed == 1)
        #expect(harness.timing.waitingCount == 1, "the click still waits for its report")
    }

    @Test("A slot with no report for 1 s closes as missed at the next report or hand-over")
    func staleSlotExpires() throws {
        let harness = Harness()
        _ = try harness.open(generated: 10_000_000_000)
        harness.clock = 11_000_000_001
        _ = try harness.open(generated: 11_000_000_000)

        #expect(harness.timing.counts.missed == 1)
        #expect(harness.slots.finished.count == 1)
        #expect(harness.slots.finished.first?.reached(.presented) == false)
        #expect(harness.timing.waitingCount == 1)
    }

    @Test("Messages that are not four numbers of a known kind are refused")
    func malformedMessagesAreRefused() throws {
        let harness = Harness()
        _ = try harness.open(generated: 10_000_000_000)
        let bodies: [Any] = [
            try Self.recorded("[0,\(Self.origin),5000]"),
            try Self.recorded("[0,\(Self.origin),5000,5010,1]"),
            try Self.recorded("[7,\(Self.origin),5000,5010]"),
            try Self.recorded("[0.5,\(Self.origin),5000,5010]"),
            try Self.recorded("[0,\(Self.origin),\"5000\",5010]"),
            try Self.recorded("[0,\(Self.origin),-1,5010]"),
            try Self.recorded("{\"kind\":0}"),
            "keydown a",
        ]
        for body in bodies {
            harness.timing.receive(body, in: nil, receivedNanos: 10_010_000_000)
        }
        #expect(harness.timing.counts.malformed == UInt64(bodies.count))
        #expect(harness.slots.finished.isEmpty)
    }

    @Test("At most 32 slots wait; the next one closes at its commit")
    func waitingIsBounded() throws {
        let harness = Harness()
        for offset in 0..<UInt64(WebPageInputTiming.pendingCapacity) {
            #expect(try harness.open(generated: 10_000_000_000 + offset * 1_000).taken)
        }
        #expect(try harness.open(generated: 10_100_000_000).taken == false)
        #expect(harness.timing.counts.refused == 1)
    }

    @Test("The page script is installed in its own world and posts numbers only")
    func scriptPostsNumbersOnly() {
        let slots = FakeSlots()
        let timing = WebPageInputTiming(slots: slots, presentation: FakePresentation())
        let controller = WKUserContentController()
        timing.install(into: controller)

        #expect(controller.userScripts.count == 1)
        let script = controller.userScripts[0]
        #expect(script.isForMainFrameOnly)
        #expect(script.injectionTime == .atDocumentStart)
        #expect(script.source == WebPageInputTiming.script)
        for field in [".key", ".code", ".target", "clientX", "screenX", "deltaX", "location", "document."] {
            #expect(!WebPageInputTiming.script.contains(field), "the page reports no \(field)")
        }
        #expect(WebPageInputTiming.script.contains("postMessage([kind, origin, start, performance.now()])"))
        #expect(WebPageInputTiming.script.contains("event.isTrusted"))
    }

    @Test("Kinds map to the page's codes")
    func pageKinds() {
        #expect(WebPageInputTiming.pageKind(.keyPress) == 0)
        #expect(WebPageInputTiming.pageKind(.mousePress) == 1)
        #expect(WebPageInputTiming.pageKind(.mouseRelease) == 2)
        for kind in [InputEventKind.scrollBegin, .scrollFirstUpdate, .scrollUpdate, .scrollMomentum] {
            #expect(WebPageInputTiming.pageKind(kind) == 3)
        }
        for kind in [InputEventKind.keyRelease, .flags, .pointerMove, .drag, .scrollEnd, .magnify] {
            #expect(WebPageInputTiming.pageKind(kind) == nil)
        }
    }
}
#endif
