import CmuxConversationGeometry
import Testing

@Suite struct ConversationStatusMotionTests {
    @Test func aStatusLandingOnItsRowGrowsInAndALeavingOneFades() {
        #expect(ConversationStatusMotion.of(sameRow: true, wasShown: false, isShown: true, wasNotDelivered: false, isFlying: false) == .grow)
        #expect(ConversationStatusMotion.of(sameRow: true, wasShown: true, isShown: false, wasNotDelivered: false, isFlying: false) == .leave)
        #expect(ConversationStatusMotion.of(sameRow: true, wasShown: true, isShown: true, wasNotDelivered: false, isFlying: false) == .none)
    }

    /// A fresh or reused cell shows its row's status in place, and Not
    /// Delivered leaves at once on Try Again (the row is moving).
    @Test func aNewRowAndTryAgainShowTheStatusInPlace() {
        #expect(ConversationStatusMotion.of(sameRow: false, wasShown: false, isShown: true, wasNotDelivered: false, isFlying: false) == .none)
        #expect(ConversationStatusMotion.of(sameRow: false, wasShown: true, isShown: false, wasNotDelivered: false, isFlying: false) == .none)
        #expect(ConversationStatusMotion.of(sameRow: true, wasShown: true, isShown: false, wasNotDelivered: true, isFlying: false) == .none)
    }

    /// The row hides its status while its send flight is in the air. A
    /// "Delivered" that arrived mid-flight (50 to 90 ms after the send on a
    /// fast link; the flight lands about 1 s after it) grew unseen under the
    /// flight and popped in at full size at the landing: it grows in when
    /// the flight lands instead. A status leaving a flying row was never
    /// seen, so it does not flash back to fade out.
    @Test func aStatusReachingAFlyingRowGrowsInWhenTheFlightLands() {
        #expect(ConversationStatusMotion.of(sameRow: true, wasShown: false, isShown: true, wasNotDelivered: false, isFlying: true) == .growOnLanding)
        #expect(ConversationStatusMotion.of(sameRow: true, wasShown: true, isShown: false, wasNotDelivered: false, isFlying: true) == .none)
    }
}
