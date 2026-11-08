import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The pin's start contract (`SidebarPinFlightTests.aPinsCurveStartsOnTheFirstFrameThatCanShowIt`: the curve begins on
/// the first frame after the turn and that frame + 1 refresh shows curve(1 refresh)) on each spring the pin films use:
/// K6 (the shipped `.move`, response 0.15, critically damped) and K12 (response 0.2, critically damped), set as the films
/// set it (`motion.spring.move`). K2 (ease-out 100 ms) is a bezier the spring tunable cannot express; the films skip it.
@MainActor @Suite(.serialized, .closesItsWindows, .enabled(if: !NSScreen.screens.isEmpty))
struct SidebarPinStartCurveTests {
    @Test(arguments: [SpringParameters?.none, SpringParameters(response: 0.2, dampingFraction: 1)])
    func aPinsCurveStartsOnTheFirstFrameOnEachFilmedSpring(_ spring: SpringParameters?) throws {
        TunableStore.shared.register(MotionTunables.all)
        let key = "motion.spring.\(MotionSpring.move.rawValue)"
        let saved = TunableStore.shared.override(key)
        if let spring { #expect(TunableStore.shared.set(key, .spring(spring)) != nil, "the film's spring was refused") }
        defer { TunableStore.shared.set(key, saved) }
        try SidebarPinFlightTests().aPinsCurveStartsOnTheFirstFrameThatCanShowIt()
    }
}
