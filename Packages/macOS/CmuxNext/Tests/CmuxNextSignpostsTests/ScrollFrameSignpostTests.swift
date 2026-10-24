@testable import CmuxNextSignposts
import Foundation
import Testing

/// `key.scroll_frame`'s begin message, which perf readers parse: the phase, and the event's age when its
/// dispatch began in milliseconds (-1 for an event with no timestamp, never negative otherwise).
@MainActor
struct ScrollFrameSignpostTests {
    @Test func theMessageCarriesThePhaseAndTheEventsAge() {
        #expect(ScrollFrameSignpost.beginMessage(phase: .changed, eventTimestamp: 10, now: 10.0125) == "phase=changed age_ms=12.50")
        #expect(ScrollFrameSignpost.beginMessage(phase: .wheel, eventTimestamp: 0, now: 10) == "phase=wheel age_ms=-1.00")
        #expect(ScrollFrameSignpost.beginMessage(phase: .began, eventTimestamp: 11, now: 10) == "phase=began age_ms=0.00")
    }

    @Test func theNameIsInTheKeyCategory() {
        #expect(SignpostName.scrollToFrame.description == "key.scroll_frame")
        #expect(SignpostName.scrollToFrame.category == .key)
    }
}
