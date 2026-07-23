import Testing
@testable import CmuxMobileTerminalKit

@Suite("Terminal back-swipe edge reservation")
struct TerminalBackSwipeEdgeReservationTests {
    @Test("left edge is reserved for system back swipe instead of terminal scroll")
    func reservesLeftEdgeForBackSwipe() {
        let reservation = TerminalBackSwipeEdgeReservation()

        #expect(reservation.shouldReserveSystemBackSwipeEdge(touchXInWindow: 0))
        #expect(reservation.shouldReserveSystemBackSwipeEdge(touchXInWindow: 31.5))
    }

    @Test("terminal scroll remains available away from the system back edge")
    func allowsTerminalScrollAwayFromBackEdge() {
        #expect(!TerminalBackSwipeEdgeReservation().shouldReserveSystemBackSwipeEdge(touchXInWindow: 33))
        #expect(!TerminalBackSwipeEdgeReservation(edgeWidth: 0).shouldReserveSystemBackSwipeEdge(touchXInWindow: 12))
    }
}
