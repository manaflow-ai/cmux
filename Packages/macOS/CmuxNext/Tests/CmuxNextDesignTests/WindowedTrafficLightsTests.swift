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

    /// The code `ShellWindow` had before the move, kept here as the reference: the same frames for every window
    /// height and every place, whole points (scale 1) and half points (scale 2).
    @Test func theFramesMatchTheCodeBeforeTheMove() {
        func before(_ lights: CGRect, notedAt noted: CGFloat, restingAt height: CGFloat) -> CGRect {
            let windowed = (x: lights.minX, fromTop: noted - lights.maxY, size: lights.size)
            return CGRect(x: windowed.x, y: height - windowed.fromTop - windowed.size.height, width: windowed.size.width, height: windowed.size.height)
        }
        let places = [CGRect(x: 12, y: 670, width: 52, height: 16), CGRect(x: 20, y: 1062, width: 54, height: 14),
                      CGRect(x: 12.5, y: 300.5, width: 52, height: 16), CGRect(x: 7, y: 0, width: 69, height: 20)]
        for place in places {
            for noted in [CGFloat(320), 720, 1080, 1440.5] where place.maxY <= noted {
                for height in [CGFloat(320), 720, 900, 1080, 2160, 1599.5] {
                    var lights = WindowedTrafficLights()
                    lights.note(place, windowHeight: noted, windowed: true)
                    #expect(lights.resting(windowHeight: height) == before(place, notedAt: noted, restingAt: height),
                            "\(place) noted at \(noted), resting at \(height)")
                }
            }
        }
    }
}
