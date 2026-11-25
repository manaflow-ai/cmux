import CmuxNextAgentPane
@testable import CmuxNextMobileHost
import Testing

/// Session Info's Remote Control row (iPhone connections) follows the iPhone host: no row while no
/// account is signed in or the build has no hostd; otherwise on as `mobile.allowIPhoneConnections` is.
@Suite struct IPhoneHostRemoteControlTests {
    @Test func theRowShowsOnlyWhenThisMacCanServePhones() {
        #expect(IPhoneHostService.remoteControlState(signedIn: false, servesPhones: true, allowed: true) == nil)
        #expect(IPhoneHostService.remoteControlState(signedIn: true, servesPhones: false, allowed: true) == nil)
        #expect(IPhoneHostService.remoteControlState(signedIn: true, servesPhones: true, allowed: true) == AgentPaneRemoteControl.State(on: true))
        #expect(IPhoneHostService.remoteControlState(signedIn: true, servesPhones: true, allowed: false) == AgentPaneRemoteControl.State(on: false))
    }
}
