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

    /// The top-left strip keeps 149 pt clear for the traffic lights and the band (its first tab at
    /// x = 151 in debug.pane_chrome), with the sidebar shown or hidden: the band's toggle stays one
    /// fixed target and the strip starts after it (Leo, T3 Code ref, 2026-10-07).
    @Test func theStripClearsTheTrafficLightsAndTheBand() {
        let lights = CGRect(x: 12, y: 698, width: 54, height: 16)
        let band = CGRect(x: 74, y: 694, width: 71, height: 24)
        #expect(TabStripView.windowControlsInset(strip: strip, lights: lights, accessory: band, padding: 2) == 149)
    }

}
