import AppKit
import CmuxNextDesign
import Testing

/// The traffic lights' windowed place, moved out of `ShellWindow` with the same answers: kept from the window's top,
/// so a window that leaves full screen at another height puts them back at the same distance from its top.
@MainActor struct WindowedTrafficLightsTests {
    @Test func theLightsKeepTheirDistanceFromTheTop() {
        var lights = WindowedTrafficLights()
        #expect(lights.resting(windowHeight: 700) == nil)
        lights.note(CGRect(x: 12, y: 670, width: 52, height: 16), windowHeight: 700, windowed: true)
        #expect(lights.resting(windowHeight: 700) == CGRect(x: 12, y: 670, width: 52, height: 16))
        #expect(lights.resting(windowHeight: 900) == CGRect(x: 12, y: 870, width: 52, height: 16))
    }

    @Test func aFullScreenPlaceIsNotKept() {
        var lights = WindowedTrafficLights()
        lights.note(CGRect(x: 12, y: 670, width: 52, height: 16), windowHeight: 700, windowed: true)
        lights.note(CGRect(x: 0, y: 0, width: 52, height: 16), windowHeight: 1000, windowed: false)
        #expect(lights.resting(windowHeight: 700) == CGRect(x: 12, y: 670, width: 52, height: 16))
    }
}
