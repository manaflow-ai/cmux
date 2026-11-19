import CmuxNextActions
import CmuxNextSidebar
import CmuxNextSidebarActions
import Testing

/// A machine header's right-click menu offers the header's screen button: Share This Mac on This Mac,
/// View Screen on Cloud and on a Mac with an online screen device, nothing on Linux or unidentified SSH.
@MainActor struct MachineHeaderScreenRowsTests {
    static let share: ActionID = "macScreen.shareThisMac", view: ActionID = "machine.viewScreen"

    static func machine(_ kind: SidebarMachine.Kind, device: String? = nil, online: Bool = true) -> SidebarMachine {
        var machine = SidebarMachine(id: kind == .local ? .local : MachineID("m"), name: "M", kind: kind)
        machine.screenDeviceID = device
        machine.screenAvailable = online
        return machine
    }

    @Test func rowsFollowTheHeaderScreenButton() {
        let device = "a1111111-1111-4111-8111-111111111111"
        #expect(SidebarScreenIntentActions.hiddenMenuRows(Self.machine(.local)) == [Self.view])
        #expect(SidebarScreenIntentActions.hiddenMenuRows(Self.machine(.cloud)) == [Self.share])
        #expect(SidebarScreenIntentActions.hiddenMenuRows(Self.machine(.ssh, device: device)) == [Self.share])
        #expect(SidebarScreenIntentActions.hiddenMenuRows(Self.machine(.server, device: device)) == [Self.share])
        #expect(SidebarScreenIntentActions.hiddenMenuRows(Self.machine(.ssh, device: device, online: false)) == [Self.share, Self.view])
        #expect(SidebarScreenIntentActions.hiddenMenuRows(Self.machine(.ssh)) == [Self.share, Self.view])
        #expect(SidebarScreenIntentActions.hiddenMenuRows(nil) == [Self.share, Self.view])
    }
}
