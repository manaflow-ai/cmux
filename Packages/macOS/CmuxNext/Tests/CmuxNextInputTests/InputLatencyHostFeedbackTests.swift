import Foundation
@testable import CmuxNextInput
import CmuxNextInputCore
import Testing

/// A Chromium host's presentation feedback: a report by the input's event time closes that input's
/// page slot with the reported time and source hostFeedback; a report that matches no open page slot changes nothing
/// and is counted.
@MainActor
@Suite(.serialized) struct InputLatencyHostFeedbackTests {
    typealias Harness = InputLatencyTrackerTests.Harness

    private func begin(_ harness: Harness, kind: InputEventKind, target: InputTarget = .chromiumPage,
                       ageNanos: UInt64 = 2_000_000) -> InputLatencyToken? {
        harness.tracker.begin(kind: kind, target: target, entrypoint: .person,
                              eventTimestamp: TimeInterval(harness.now - ageNanos) / 1e9, window: nil)
    }

    /// A tracker whose pages report their presented frames (a host that announced it in its `ready`).
    private func reportingHarness() -> Harness {
        let harness = Harness()
        harness.tracker.pagesReportPresentation = true
        return harness
    }

    /// The event time of `token`'s slot: what the page view sent as the input frame's `t0`.
    private func eventNanos(_ harness: Harness, _ token: InputLatencyToken) throws -> UInt64 {
        try #require(harness.tracker.table.time(token, .generated))
    }

    @Test("A host's report closes the page slot of its event time at once, as hostFeedback")
    func hostReportClosesThePageSlotByEventTime() throws {
        let harness = reportingHarness()
        let first = try #require(begin(harness, kind: .mousePress, ageNanos: 3_000_000))
        let second = try #require(begin(harness, kind: .mouseRelease, ageNanos: 1_000_000))
        let firstEvent = try eventNanos(harness, first)
        let secondEvent = try eventNanos(harness, second)
        harness.commit()
        #expect(harness.tracker.waitingCount == 2)

        let shown = harness.advance(8_000_000)
        #expect(harness.tracker.hostPresented(eventNanos: secondEvent, at: shown))
        let slot = try #require(harness.emitted.first)
        #expect(harness.emitted.count == 1, "the report closes its slot with no commit")
        #expect(slot.kind == .mouseRelease && slot.target == .chromiumPage)
        #expect(slot.presented == shown && slot.presentationSource == .hostFeedback)
        #expect(slot.nanos(from: .generated, to: .presented) == shown - secondEvent)
        #expect(harness.tracker.waitingCount == 1, "the other page slot keeps waiting")
        #expect(harness.presentation.asked.isEmpty, "a reported time asks for no estimate")
        #expect(harness.tracker.unmatchedHostPresentations == 0)

        #expect(harness.tracker.hostPresented(eventNanos: firstEvent, at: shown))
        #expect(harness.emitted.map(\.kind) == [.mouseRelease, .mousePress])
        #expect(harness.tracker.waitingCount == 0)
    }

    @Test("A host's report for a page slot still in its turn closes it at the turn's commit")
    func hostReportInTheTurnClosesAtTheCommit() throws {
        let harness = reportingHarness()
        let token = try #require(begin(harness, kind: .keyPress))
        let event = try eventNanos(harness, token)
        let shown = harness.advance(4_000_000)
        #expect(harness.tracker.hostPresented(eventNanos: event, at: shown))
        #expect(harness.emitted.isEmpty, "the slot closes with its turn")
        harness.tracker.endDispatch(token)
        harness.commit()
        let slot = try #require(harness.emitted.first)
        #expect(slot.presented == shown && slot.presentationSource == .hostFeedback && slot.reached(.mainCommit))
        #expect(harness.tracker.waitingCount == 0 && harness.tracker.pendingCount == 0)
    }

    @Test("A host's report that matches no open page slot changes nothing and is counted")
    func unmatchedHostReportsAreCounted() throws {
        let harness = reportingHarness()
        let page = try #require(begin(harness, kind: .mousePress, ageNanos: 2_000_000))
        let view = try #require(begin(harness, kind: .mousePress, target: .textView, ageNanos: 1_000_000))
        let pageEvent = try eventNanos(harness, page)
        let viewEvent = try eventNanos(harness, view)
        harness.tracker.endDispatch(view)
        harness.commit()
        #expect(harness.emitted.map(\.target) == [.textView])
        let now = harness.advance(1_000_000)

        #expect(!harness.tracker.hostPresented(eventNanos: pageEvent + 1, at: now), "no slot has that event time")
        #expect(!harness.tracker.hostPresented(eventNanos: viewEvent, at: now), "a view's slot is not a page's")
        #expect(!harness.tracker.hostPresented(eventNanos: pageEvent, at: pageEvent - 1), "presented before the event")
        #expect(!harness.tracker.hostPresented(eventNanos: 0, at: now), "no event time")
        #expect(harness.tracker.unmatchedHostPresentations == 4)
        #expect(harness.emitted.count == 1 && harness.tracker.waitingCount == 1, "the page slot still waits")

        // After its deadline the slot closes as a no-echo slot; a report then is counted, not stamped.
        let late = harness.advance(InputLatencyTracker.contentDeadlineNanos)
        #expect(!harness.tracker.hostPresented(eventNanos: pageEvent, at: late))
        #expect(harness.tracker.unmatchedHostPresentations == 5)
        let slot = try #require(harness.emitted.last)
        #expect(slot.target == .chromiumPage && !slot.reached(.presented))
        #expect(harness.tracker.waitingCount == 0)
        #expect(!harness.tracker.hostPresented(eventNanos: pageEvent, at: late), "its slot closed")
        #expect(harness.tracker.unmatchedHostPresentations == 6)
    }

    @Test("While pages report, a page slot with no report waits after its turn and closes at the deadline unpresented")
    func reportingPageWaitsForItsReport() throws {
        let harness = reportingHarness()
        let token = try #require(begin(harness, kind: .mousePress))
        harness.tracker.endDispatch(token)
        harness.commit()
        #expect(harness.emitted.isEmpty && harness.tracker.waitingCount == 1, "the page's frame comes after the commit")
        #expect(harness.presentation.asked.isEmpty, "no commit estimate for a page whose host reports")
        harness.advance(InputLatencyTracker.contentDeadlineNanos + 1)
        harness.commit()
        let slot = try #require(harness.emitted.first)
        #expect(slot.target == .chromiumPage && slot.reached(.mainCommit) && !slot.reached(.presented))
    }

    @Test("While no page reports, a page slot closes at its turn's commit with the commit's vsync estimate")
    func silentPageClosesWithTheCommitEstimate() throws {
        let harness = Harness()
        #expect(!harness.tracker.pagesReportPresentation, "no fork has the feedback yet: off by default")
        let token = try #require(begin(harness, kind: .keyPress))
        harness.tracker.endDispatch(token)
        harness.commit()
        let slot = try #require(harness.emitted.first)
        #expect(harness.tracker.waitingCount == 0, "nothing to wait for")
        #expect(harness.presentation.asked == [slot.mainCommit], "the turn's commit is the page's estimate")
        #expect(slot.target == .chromiumPage && slot.reached(.presented))
        #expect(slot.presentationSource == .estimatedVsync)
        #expect(slot.presented == slot.mainCommit + InputLatencyTrackerTests.FakePresentation.renderServerNanos)
        // A report after the slot closed finds nothing.
        #expect(!harness.tracker.hostPresented(eventNanos: slot.generated, at: harness.advance(1_000_000)))
        #expect(harness.tracker.unmatchedHostPresentations == 1)
    }

    @Test("Event nanoseconds round the event's seconds as the generated stage does, so a host frame's t0 matches")
    func eventNanosMatchTheGeneratedStage() throws {
        let harness = Harness()
        let timestamp = TimeInterval(harness.now - 1_234_567) / 1e9
        let token = try #require(harness.tracker.begin(kind: .keyPress, target: .chromiumPage, entrypoint: .person,
                                                       eventTimestamp: timestamp, window: nil))
        #expect(try eventNanos(harness, token) == InputLatencyTracker.eventNanos(timestamp))
        #expect(InputLatencyTracker.eventNanos(0) == 0 && InputLatencyTracker.eventNanos(-1) == 0)
    }
}
