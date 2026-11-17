import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
@testable import CmuxNextHome
@testable import CmuxNextTabs
import Testing

/// cmux#25593: the docked Home pane has no tab bar, so with the sidebar hidden (Cmd+B) Home's list
/// sat at the window's top-left under the traffic lights. The list is the React Messages page's now;
/// what stays native is the shared measure of what lies under the window controls.
@MainActor struct HomeHeaderTrafficLightsTests {
    /// The shared measure (`WindowTitlebar.windowControlsMaxX`): only what lies over the shown part counts.
    @Test func onlyObstaclesOverTheShownPartCount() {
        let lights = CGRect(x: 8, y: 600, width: 52, height: 16)
        let row = CGRect(x: 0, y: 596, width: 300, height: 28)
        #expect(WindowTitlebar.windowControlsMaxX(over: row, shown: .infinite, lights: lights, accessory: nil) == 60)
        // Below the lights, or with the row's part under them clipped away: nothing to clear.
        #expect(WindowTitlebar.windowControlsMaxX(over: row.offsetBy(dx: 0, dy: -60), shown: .infinite, lights: lights, accessory: nil) == nil)
        #expect(WindowTitlebar.windowControlsMaxX(over: row, shown: CGRect(x: 100, y: 0, width: 900, height: 700), lights: lights, accessory: nil) == nil)
        // The open toolbar band after the lights (the accessory) is cleared too.
        let band = CGRect(x: 72, y: 598, width: 90, height: 20)
        #expect(WindowTitlebar.windowControlsMaxX(over: row, shown: .infinite, lights: lights, accessory: band) == 162)
    }
}
