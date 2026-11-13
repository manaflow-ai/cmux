import CmuxDeviceHub
import CmuxMobileLive
import Testing
@testable import CmuxMobileShell

#if os(iOS)
/// The device hub socket's states as the connectivity incident reporter's `device_hub` surface.
@Suite struct HubSocketIncidentTests {
    @Test func aRestartIsStillWantedAndOnlySignOutOrATerminalCloseEndsIt() {
        #expect(ShellModel.hubSocketEvent(.connecting) == .dialing)
        #expect(ShellModel.hubSocketEvent(.connected) == .connected)
        #expect(ShellModel.hubSocketEvent(.reconnecting("hub down")) == .failed(reason: "hub down"))
        // Review finding 2: a restart (pull to refresh) is not "stopped using it"; a registration that
        // then fails starts no socket and must keep the outage counting.
        #expect(ShellModel.hubSocketEvent(.disconnected) == .restarting)
        #expect(ShellModel.hubSocketEvent(.replaced) == .closed)
        #expect(ShellModel.hubSocketEvent(.removed) == .closed)
        #expect(ShellModel.hubSocketEvent(.signedOut) == .closed)
        #expect(ShellModel.hubSocketEvent(nil) == .closed)
    }
}
#endif
