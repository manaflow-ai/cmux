import AppKit
import CmuxNextDevices
import CmuxNextDesign
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWakeups
@testable import CmuxNextSidebar
import Testing

@MainActor @Suite(.serialized) struct SidebarScreenActionTests {
    static func section(_ id: String, name: String, kind: SidebarMachine.Kind, device: String? = nil, online: Bool = true) -> SidebarSection {
        var machine = SidebarMachine(id: MachineID(id), name: name, kind: kind)
        machine.screenDeviceID = device
        machine.screenAvailable = online
        return SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-" + id), title: "A project with a long descriptive title", directory: "~/Projects"))])
    }

    static var examples: [SidebarSection] {
        [section("local", name: "This Mac", kind: SidebarMachine.Kind.local),
         section("mac", name: "A very long Mac Studio device name", kind: SidebarMachine.Kind.server, device: "device-mac"),
         section("cloud", name: "Cloud development environment with a long name", kind: SidebarMachine.Kind.cloud),
         section("offline", name: "MacBook Pro offline", kind: SidebarMachine.Kind.server, device: "device-offline", online: false),
         section("linux", name: "Linux SSH build machine", kind: SidebarMachine.Kind.ssh)]
    }

    @Test func defaultFlatListMountsShareWithoutAddingMachineHeaders() throws {
        _ = NSApplication.shared
        let model = SidebarModel(sections: [Self.examples[0]])
        model.groupsByComputer = false
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let header = try #require(list.rowViews.values.compactMap { $0 as? ListHeaderRowView }.first)
        #expect(header.allowsShare)
        #expect(!header.screenButton.isHidden)
        #expect(header.screenButton.accessibilityPerformPress())
        #expect(intents == [.shareScreen(.local)])
        #expect(!list.rowViews.values.contains { $0 is SectionHeaderRowView })
    }

    @Test(arguments: [240.0, 300.0, 360.0])
    func flatWorkspaceActionsKeepTitlesAndHoverControlsClear(width: Double) throws {
        _ = NSApplication.shared
        let model = SidebarModel(sections: Self.examples)
        model.groupsByComputer = false
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        let list = SidebarListView(model: model)
        list.contextMenuProvider = { _ in NSMenu() }
        list.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        #expect(!list.rowViews.values.contains { $0 is SectionHeaderRowView })
        for id in ["mac", "cloud", "offline"] {
            let row = try #require(list.rowViews[.workspace(WorkspaceID("ws-" + id))] as? WorkspaceRowView)
            let button = try #require(row.screenSlot.made)
            #expect(!button.isHidden)
            #expect(button.accessibilityPerformPress() == (id != "offline"))
            if id != "offline" { #expect(intents.last == .viewScreen(MachineID(id))) }
            let titleAtRest = row.title.frame
            #expect(titleAtRest.width >= 2 * SidebarStyle.controlSize, "the project title retains usable text space")
            #expect(titleAtRest.maxX <= button.frame.minX)
            #expect(row.subtitle.frame.maxX <= button.frame.minX)
            row.isHovered = true
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            #expect(row.title.frame == titleAtRest, "hover reveals controls without moving the title")
            for control in ([row.closeSlot.made, row.moreSlot.made] as [NSView?]) {
                let control = try #require(control)
                #expect(!control.isHidden)
                #expect(!control.frame.intersects(button.frame))
            }
            #expect(!row.closeSlot.frame.intersects(row.moreSlot.frame))
        }
        for id in ["local", "linux"] {
            let row = try #require(list.rowViews[.workspace(WorkspaceID("ws-" + id))] as? WorkspaceRowView)
            #expect(row.screenMachineID == nil)
            #expect(row.screenSlot.made == nil)
        }
        model.sections = [Self.section("mac", name: "Now Linux", kind: SidebarMachine.Kind.ssh)]
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let reused = try #require(list.rowViews[.workspace(WorkspaceID("ws-mac"))] as? WorkspaceRowView)
        #expect(reused.screenMachineID == nil)
        if let button = reused.screenSlot.made {
            #expect(button.isHidden)
            #expect(!button.accessibilityPerformPress())
        }
        model.sections = Self.examples
        model.groupsByComputer = true
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        for row in list.rowViews.values.compactMap({ $0 as? WorkspaceRowView }) {
            #expect(row.screenMachineID == nil, "grouped rows use their machine header action")
        }
    }

    @Test(arguments: [240.0, 300.0, 360.0])
    func groupedMachineNamesKeepUsableWidthBesideScreenActions(width: Double) throws {
        _ = NSApplication.shared
        let model = SidebarModel(sections: Self.examples)
        model.groupsByComputer = true
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        for section in Self.examples {
            let machine = try #require(section.machine)
            guard ["mac", "cloud", "offline"].contains(machine.id.rawValue) else { continue }
            let row = try #require(list.rowViews[.section(section.id)] as? SectionHeaderRowView)
            let name = try #require(row.subviews.compactMap { $0 as? ChromeLabel }.first { $0.stringValue == machine.name })
            let nameAtRest = name.frame
            #expect(!name.isHidden)
            #expect(nameAtRest.width >= 2 * SidebarStyle.controlSize, "long machine names retain usable text space")
            #expect(row.allowsAdd)
            #expect(row.showsChevron)
            #expect(row.showsScreenButton)
            for hovered in [false, true, false] {
                row.isHovered = hovered
                row.needsLayout = true
                row.layoutSubtreeIfNeeded()
                #expect(name.frame == nameAtRest, "showing + must not move or narrow the machine name")
                #expect(row.addButton.isHidden == !hovered)
                for frame in [row.screenButtonFrame, row.chevronFrame, row.addButton.frame] {
                    #expect(!name.frame.intersects(frame))
                    #expect(name.frame.maxX <= frame.minX)
                }
                #expect(!row.screenButtonFrame.intersects(row.chevronFrame))
                #expect(!row.screenButtonFrame.intersects(row.addButton.frame))
                #expect(!row.chevronFrame.intersects(row.addButton.frame))
            }
        }
    }

    @Test func mountedMachineActionsRouteAndResetWhenReused() throws {
        _ = NSApplication.shared
        let model = SidebarModel(sections: Self.examples)
        model.groupsByComputer = true
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 1000)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        for (id, expected) in [("local", SidebarIntent.shareScreen(.local)), ("mac", .viewScreen(MachineID("mac"))), ("cloud", .viewScreen(MachineID("cloud")))] {
            let row = try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID(id)))] as? SectionHeaderRowView)
            #expect(row.showsScreenButton)
            #expect(row.screenButton.accessibilityPerformPress())
            #expect(intents.last == expected)
            #expect(!row.screenButtonFrame.intersects(row.chevronFrame))
        }
        let offline = try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID("offline")))] as? SectionHeaderRowView)
        #expect(offline.showsScreenButton)
        #expect(!offline.screenButton.accessibilityPerformPress())
        let linux = try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID("linux")))] as? SectionHeaderRowView)
        #expect(!linux.showsScreenButton)
        model.sections = [Self.section("mac", name: "Now a Linux machine", kind: SidebarMachine.Kind.ssh)]
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let reused = try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID("mac")))] as? SectionHeaderRowView)
        #expect(reused.screenAction == nil)
        #expect(!reused.screenButton.accessibilityPerformPress())
    }

    @Test func sourceAdapterUsesActualDaemonRouteAndScreenIdentity() throws {
        let deviceID = "a1111111-1111-4111-8111-111111111111"
        let routeID = "ssh-actual-route", meshID = "inst-unrelated-mesh"
        let daemon = DaemonService(machineID: routeID, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        daemon.store.noteHandshake(DaemonIdentity(machineResourceID: ResourceID(rawValue: "machine_credentials"),
                                                 screenDeviceID: deviceID.uppercased(), generation: "boot"))
        let aliases = DaemonService.screenDeviceAliases(in: [daemon])
        #expect(aliases == [routeID: deviceID])
        #expect(aliases[meshID] == nil)
        let devices = [HubDevice(id: deviceID, name: "Renamed Mac", platform: .macos, macScreenShared: false, online: true),
                       HubDevice(id: "phone", name: "Phone", platform: .ios, online: true)]
        let input = [Self.section(routeID, name: "Old name", kind: SidebarMachine.Kind.ssh), Self.section("linux", name: "Renamed Mac", kind: SidebarMachine.Kind.ssh),
                     Self.section("phone", name: "Phone", kind: SidebarMachine.Kind.server),
                     Self.section(deviceID, name: "Renamed Mac", kind: SidebarMachine.Kind.ssh)]
        let actions = SidebarScreenActions(macs: HubDevice.macScreenAvailability(in: devices), aliases: aliases)
        let result = actions.applying(to: input)
        #expect(result[0].machine?.screenDeviceID == deviceID, "A Mac can open the guided sharing flow before sharing is enabled")
        #expect(result[0].machine?.screenAvailable == true)
        #expect(result[1].machine?.screenDeviceID == nil)
        #expect(result[2].machine?.screenDeviceID == nil)
        #expect(result[3].machine?.screenDeviceID == nil, "A UUID-looking route still needs its authenticated screen identity")
        let offline = SidebarScreenActions(macs: HubDevice.macScreenAvailability(in: [HubDevice(id: deviceID, name: "Mac", platform: .macos)]), aliases: aliases).applying(to: input)
        #expect(offline[0].machine?.screenDeviceID == deviceID)
        #expect(offline[0].machine?.screenAvailable == false)

        _ = NSApplication.shared
        let model = SidebarModel(sections: result)
        model.groupsByComputer = true
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let mac = try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID(routeID)))] as? SectionHeaderRowView)
        #expect(mac.screenButton.accessibilityPerformPress())
        #expect(intents == [.viewScreen(MachineID(routeID))])
        let linux = try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID("linux")))] as? SectionHeaderRowView)
        #expect(!linux.showsScreenButton)
    }
}
