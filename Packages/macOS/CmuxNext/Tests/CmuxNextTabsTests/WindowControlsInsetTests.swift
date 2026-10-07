import CoreGraphics
@testable import CmuxNextTabs
import Testing

/// The incognito badge sits after the traffic lights in the top row when
/// the sidebar is hidden; the strip under it starts its tabs after it.
@MainActor
struct WindowControlsInsetTests {
    let lights = CGRect(x: 12, y: 700, width: 52, height: 14)
    let badge = CGRect(x: 76, y: 698, width: 90, height: 18)
    let strip = CGRect(x: 0, y: 690, width: 800, height: 34)

    @Test func theStripClearsTheBadge() {
        let without = TabStripView.windowControlsInset(strip: strip, lights: lights, accessory: nil, padding: 4)
        let with = TabStripView.windowControlsInset(strip: strip, lights: lights, accessory: badge, padding: 4)
        #expect(without < badge.maxX)
        #expect(with >= badge.maxX - 4)
    }

    /// Full screen hides the traffic lights; the badge still takes room.
    @Test func theBadgeTakesRoomWithoutTrafficLights() {
        #expect(TabStripView.windowControlsInset(strip: strip, lights: nil, accessory: badge, padding: 4) >= badge.maxX - 4)
        #expect(TabStripView.windowControlsInset(strip: strip, lights: nil, accessory: nil, padding: 4) == 0)
    }

    /// With the sidebar hidden, the top-left strip keeps 149 pt clear (its first tab at x = 151 in
    /// debug.pane_chrome) for the traffic lights and the titlebar band, at rest and on hover:
    /// the traffic lights always show (TRAFFIC-LIGHTS-ALWAYS-AND-CLEAN-SIDEBAR-TOGGLE).
    @Test func theStripClearsTheTrafficLightsAndTheBand() {
        let lights = CGRect(x: 12, y: 698, width: 54, height: 16)
        let band = CGRect(x: 74, y: 694, width: 71, height: 24)
        let inset = TabStripView.windowControlsInset(strip: strip, lights: lights, accessory: band, padding: 2)
        #expect(inset == 149, "the measured inset (first tab at 151 = padding 2 + 149)")
    }

    /// A strip that is not under the top-left corner keeps nothing clear.
    @Test func aStripAwayFromTheCornerKeepsNothingClear() {
        let right = CGRect(x: 400, y: 690, width: 400, height: 34)
        #expect(TabStripView.windowControlsInset(strip: right, lights: lights, accessory: badge, padding: 4) == 0)
    }
}
