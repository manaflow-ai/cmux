import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The New Tab page's `tab.jump` carries the page's click or Return that picked the place (`inputAt`, Unix ms), and
/// the host reads it as an `NSEvent.timestamp`, so the switch it makes a turn later reports that input's age.
struct AgentPaneJumpInputTests {
    @Test func aJumpDecodesThePagesInputTime() {
        let picked = AgentPaneRequest(body: ["method": "tab.jump", "params": ["target": "workspace", "id": "w1", "inputAt": 1_700_000_000_250.5]])
        #expect(picked == .jump(.workspace, id: "w1", inputAt: 1_700_000_000_250.5))
        #expect(AgentPaneRequest(body: ["method": "tab.jump", "params": ["target": "tab", "id": "t1"]]) == .jump(.tab, id: "t1", inputAt: nil))
        for bad in ["soon", -5, 0] as [Any] {
            #expect(AgentPaneRequest(body: ["method": "tab.jump", "params": ["target": "tab", "id": "t1", "inputAt": bad]]) == .jump(.tab, id: "t1"),
                    "\(bad) is no input time")
        }
    }

    /// Read against one instant of both clocks: 3 ms before now on the wall clock is 3 ms before now in uptime.
    @Test func thePagesInputTimeIsReadAsUptime() throws {
        let wallNow = Date(timeIntervalSince1970: 1_700_000_000)
        let uptime = try #require(AgentPaneRequest.uptime(ofPageInputAt: 1_699_999_999_997, wallNow: wallNow, uptimeNow: 50))
        #expect(abs(uptime - 49.997) < 1e-6)
        #expect(AgentPaneRequest.uptime(ofPageInputAt: 1_700_000_000_005, wallNow: wallNow, uptimeNow: 50) == nil, "a stamp after now")
    }
}
