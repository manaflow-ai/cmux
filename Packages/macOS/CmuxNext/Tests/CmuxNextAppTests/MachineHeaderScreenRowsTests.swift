import AppKit
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

    /// This Mac alone draws its header as the list's "Projects" title, whose menu is the sidebar's own: it still
    /// leads with Share This Mac, the row This Mac's header has when other machines are listed (review F1, #47230).
    @Test func theProjectsTitleMenuLeadsWithShareThisMac() {
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: Self.share, title: "Share This Mac", category: .other)])
        let menu = NSMenu()
        menu.addItem(withTitle: "New Project", action: nil, keyEquivalent: "")
        SidebarScreenIntentActions.addShareThisMacRow(to: menu, registry: registry)
        #expect(menu.items.map(\.title) == ["Share This Mac", "", "New Project"])
        #expect(menu.items[1].isSeparatorItem)
        #expect(SidebarScreenIntentActions.addShareThisMacRow(to: NSMenu(), registry: ActionRegistry(catalog: [])).items.isEmpty)
    }
}
