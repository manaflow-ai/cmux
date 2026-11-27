import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// The press and drag math of the thin scroller (ThinScrollerGrabZoneTests drives it with events):
/// where a press lands along the bar, and the value a drag or a jump gives.
struct ThinScrollerTrackTests {
    /// A 200 pt slot from 0 with a 50 pt knob at 30.
    let track = ThinScrollerTrack(slotStart: 0, slotLength: 200, knobStart: 30, knobLength: 50)

    @Test func aPressLandsBeforeOnOrAfterTheKnobHalfOpen() {
        #expect(track.part(at: 29.9) == .before)
        #expect(track.part(at: 30) == .knob)
        #expect(track.part(at: 79.9) == .knob)
        #expect(track.part(at: 80) == .after)
    }

    /// The knob's start moves point for point with the value over its travel, clamped at both ends.
    @Test func theValuePutsTheKnobStartWhereTheDragTakesIt() {
        #expect(track.travel == 150)
        #expect(track.value(knobStart: 0) == 0)
        #expect(track.value(knobStart: 75) == 0.5)
        #expect(track.value(knobStart: 150) == 1)
        #expect(track.value(knobStart: -40) == 0)
        #expect(track.value(knobStart: 400) == 1)
    }

    @Test func aJumpCentersTheKnobOnThePress() {
        #expect(track.value(centeredAt: 100) == 0.5)
        #expect(track.value(centeredAt: 5) == 0)
    }

    @Test func aKnobAsLongAsTheSlotHasNoTravel() {
        let full = ThinScrollerTrack(slotStart: 0, slotLength: 100, knobStart: 0, knobLength: 100)
        #expect(full.value(knobStart: 30) == 0)
    }
}
