import CmuxNextRemote
import Testing
@testable import CmuxNextApp

/// An ssh machine header's tooltip, composed once (`SidebarBridge.sshTooltip`) for the live header
/// and for `debug.daemon_update`'s capture fixture, so a capture shows what a person sees.
struct SSHMachineTooltipTests {
    @Test @MainActor func theTooltipIsTheDestinationTheSessionAndTheDetail() throws {
        let destination = try SSHDestination(parsing: "dev@build-box.example.com:2222")
        #expect(SidebarBridge.sshTooltip(destination: destination, session: RemoteSessionName.defaultName, detail: "Connected")
            == "dev@build-box.example.com:2222\nConnected")
        #expect(SidebarBridge.sshTooltip(destination: destination, session: "work", detail: "Connected")
            == "dev@build-box.example.com:2222 · work\nConnected")
        #expect(SidebarBridge.sshTooltip(destination: destination, session: RemoteSessionName.defaultName, detail: nil)
            == "dev@build-box.example.com:2222")
        #expect(SidebarBridge.sshTooltip(destination: destination, session: RemoteSessionName.defaultName, detail: "")
            == "dev@build-box.example.com:2222", "an empty line is left out")
    }
}
