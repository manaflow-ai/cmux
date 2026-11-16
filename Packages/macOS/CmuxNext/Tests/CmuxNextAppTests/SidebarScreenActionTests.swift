import AppKit
import CmuxNextDevices
import CmuxNextDesign
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWakeups
@testable import CmuxNextSidebar
import Testing

@MainActor @Suite(.serialized) struct SidebarScreenActionTests {
    static func section(_ id: String, name: String, kind: SidebarMachine.Kind, device: String? = nil, online: Bool = true) -> CmuxNextSidebar.SidebarSection {
        var machine = SidebarMachine(id: MachineID(id), name: name, kind: kind)
        machine.screenDeviceID = device
        machine.screenAvailable = online
        return CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-" + id), title: "A project with a long descriptive title", directory: "~/Projects"))])
    }

    static func sharedLocal() -> CmuxNextSidebar.SidebarSection {
        var section = section("local", name: "This Mac", kind: SidebarMachine.Kind.local)
        guard case var .machine(machine) = section.kind else { return section }
        machine.screenShared = true
        section.kind = .machine(machine)
        return section
    }

    static func lay(_ row: SidebarRowView, hovered: Bool? = nil, selected: Bool? = nil) {
        if let hovered { row.isHovered = hovered }
        if let selected { row.isSelected = selected }
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
    }

    static func customAction(_ row: NSView, named name: String) -> NSAccessibilityCustomAction? {
        row.accessibilityCustomActions()?.first { $0.name.hasPrefix(name) }
    }

    static var examples: [CmuxNextSidebar.SidebarSection] {
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
        let row = try #require(list.rowViews[.workspace(WorkspaceID("ws-local"))] as? WorkspaceRowView)
        #expect(row.screenAction == nil)
        #expect(row.screenSlot.made == nil)
        #expect(!list.rowViews.values.contains { $0 is ListHeaderRowView })
        #expect(intents.isEmpty)
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
        let headers = list.rowViews.values.compactMap { $0 as? SectionHeaderRowView }
        #expect(!headers.isEmpty, "flat layouts retain machine headers so Add remains reachable")
        #expect(headers.allSatisfy { !$0.addButton.isHidden }, "Add stays visible in the flat layout")
        for id in ["mac", "cloud", "offline"] {
            let row = try #require(list.rowViews[.workspace(WorkspaceID("ws-" + id))] as? WorkspaceRowView)
            // Leo 2026-11-16: nothing on every row at rest. View screen draws on hover or selection only.
            #expect(row.screenAction != nil)
            #expect(row.screenSlot.made.map { $0.isHidden || $0.alphaValue == 0 } ?? true, "no screen button at rest")
            let titleAtRest = row.title.frame
            #expect(titleAtRest.width >= 2 * SidebarStyle.controlSize, "the project title retains usable text space")
            let action = Self.customAction(row, named: Strings.viewScreen)
            #expect((action != nil) == (id != "offline"), "VoiceOver reaches View screen while the button hides")
            if id != "offline" {
                #expect(action?.handler?() == true)
                #expect(intents.last == .viewScreen(MachineID(id)))
            }
            Self.lay(row, hovered: true)
            let button = try #require(row.screenSlot.made)
            #expect(!button.isHidden && button.alphaValue > 0)
            #expect(button.icon == .remoteDisplay)
            #expect(row.title.frame == titleAtRest, "hover reveals controls without moving the title")
            for control in ([row.closeSlot.made, row.moreSlot.made] as [NSView?]) {
                let control = try #require(control)
                #expect(!control.isHidden)
                #expect(!control.frame.intersects(button.frame))
            }
            #expect(!row.closeSlot.frame.intersects(row.moreSlot.frame))
            #expect(button.accessibilityPerformPress() == (id != "offline"))
            Self.lay(row, hovered: false, selected: true)
            #expect(!button.isHidden && button.alphaValue > 0, "the selected row shows View screen")
            #expect(row.title.frame == titleAtRest, "selection moves no title")
            Self.lay(row, selected: false)
            #expect(button.isHidden || button.alphaValue == 0)
        }
        for id in ["local", "linux"] {
            let row = try #require(list.rowViews[.workspace(WorkspaceID("ws-" + id))] as? WorkspaceRowView)
            #expect(row.screenAction == nil)
            #expect(row.screenSlot.made == nil)
        }
        model.sections = [Self.section("mac", name: "Now Linux", kind: SidebarMachine.Kind.ssh)]
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let reused = try #require(list.rowViews[.workspace(WorkspaceID("ws-mac"))] as? WorkspaceRowView)
        #expect(reused.screenAction == nil)
        if let button = reused.screenSlot.made {
            #expect(button.isHidden)
            #expect(!button.accessibilityPerformPress())
        }
        model.sections = Self.examples
        model.groupsByComputer = true
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        for row in list.rowViews.values.compactMap({ $0 as? WorkspaceRowView }) {
            #expect(row.screenAction == nil, "grouped rows use their machine header action")
        }
    }

    /// A selected row's screen button (no ⋮ or ✕ show) lands on the keycap's slot when a status glyph holds the
    /// column, so the keycap gives way there; with the column free the keycap sits clear of it and stays.
    @Test(arguments: [false, true])
    func theSelectedRowsScreenButtonHidesOnlyTheKeycapUnderIt(busy: Bool) throws {
        _ = NSApplication.shared
        var cloud = Self.section("cloud", name: "Cloud", kind: SidebarMachine.Kind.cloud)
        cloud.nodes = [.workspace(SidebarWorkspace(id: WorkspaceID("ws-cloud"), title: "A project with a long descriptive title",
                                                   directory: "~/Projects", activity: busy ? .busy(progress: nil) : .idle))]
        let model = SidebarModel(sections: [cloud])
        model.groupsByComputer = false
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let row = try #require(list.rowViews[.workspace(WorkspaceID("ws-cloud"))] as? WorkspaceRowView)
        row.keycap.configure(3)
        let drawn = { (view: NSView) in !view.isHidden && view.alphaValue > 0 }
        Self.lay(row, hovered: false, selected: false)
        #expect(drawn(row.keycap), "the keycap shows at rest")
        Self.lay(row, selected: true)
        let button = try #require(row.screenSlot.made)
        #expect(drawn(button))
        let under = row.keycap.frame.intersects(button.frame)
        if busy { #expect(under, "with the column held, the keycap's slot is the screen button's") }
        #expect(drawn(row.keycap) == !under, "the keycap hides only under the screen button")
        Self.lay(row, selected: false)
        #expect(drawn(row.keycap), "the keycap comes back")
    }

    @Test func aReusedFlatScreenButtonChangesItsTargetAndLabel() throws {
        _ = NSApplication.shared
        let model = SidebarModel(sections: Self.examples)
        model.groupsByComputer = false
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 1000)
        list.reload(animated: false)
        let row = try #require(list.rowViews[.workspace(WorkspaceID("ws-mac"))] as? WorkspaceRowView)
        let button = try #require(row.screenSlot.made)
        row.configureScreen(Self.examples[0].machine)
        #expect(button.isHidden)
        #expect(!button.accessibilityPerformPress())
        #expect(intents.isEmpty)
        row.configureScreen(Self.examples[1].machine)
        #expect(button.label == Strings.viewScreen)
        #expect(button.icon == .remoteDisplay)
        Self.lay(row, hovered: true)
        #expect(button.accessibilityPerformPress())
        #expect(intents.last == .viewScreen(MachineID("mac")))
        row.configureScreen(nil)
        #expect(button.isHidden)
        #expect(!button.accessibilityPerformPress())
        #expect(intents.count == 1)
    }

    /// Leo 2026-11-16: "A workspace that is actually being shared shows a state badge." While this Mac shares, the
    /// local row on screen draws the screen glyph in the accent at rest; other local rows draw nothing, hovered or not.
    @Test func theSharedRowAloneShowsTheSharingBadge() throws {
        _ = NSApplication.shared
        var other = Self.sharedLocal()
        other.nodes = [.workspace(SidebarWorkspace(id: WorkspaceID("ws-local-2"), title: "Another local project", directory: "~/Projects"))]
        var shared = Self.sharedLocal()
        shared.nodes += other.nodes
        let model = SidebarModel(sections: [shared])
        model.groupsByComputer = false
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let onScreen = try #require(list.rowViews[.workspace(WorkspaceID("ws-local"))] as? WorkspaceRowView)
        let rest = try #require(list.rowViews[.workspace(WorkspaceID("ws-local-2"))] as? WorkspaceRowView)
        Self.lay(rest, hovered: true)
        #expect(rest.screenSlot.made.map { $0.isHidden || $0.alphaValue == 0 } ?? true, "no Share button on a local row, even hovered")
        Self.lay(rest, hovered: false)
        onScreen.isOnScreen = true
        Self.lay(onScreen, selected: true)
        let badge = try #require(onScreen.screenSlot.made)
        #expect(!badge.isHidden && badge.alphaValue > 0, "the shared row shows the badge at rest")
        #expect(badge.icon == .remoteDisplay)
        #expect(badge.tintOverride == Palette.accent)
        #expect(badge.label == Strings.sharingScreen)
        onScreen.isOnScreen = false
        Self.lay(onScreen, selected: false)
        #expect(badge.isHidden || badge.alphaValue == 0, "the badge follows the row on screen")
        // Sharing stops: the local rows go back to no screen control at all.
        model.sections = [Self.section("local", name: "This Mac", kind: SidebarMachine.Kind.local)]
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let stopped = try #require(list.rowViews[.workspace(WorkspaceID("ws-local"))] as? WorkspaceRowView)
        Self.lay(stopped, selected: true)
        #expect(stopped.screenAction == nil)
        #expect(stopped.screenSlot.made.map { $0.isHidden } ?? true)
    }

    @Test func headersShowTheScreenButtonOnHoverOrAsTheSharingBadge() throws {
        _ = NSApplication.shared
        let model = SidebarModel(sections: [Self.sharedLocal()] + Self.examples.dropFirst())
        model.groupsByComputer = true
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 1000)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let local = try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID("local")))] as? SectionHeaderRowView)
        #expect(local.showsScreenButton, "This Mac's header shows the sharing badge at rest while it shares")
        #expect(local.screenButton.icon == .remoteDisplay)
        #expect(local.screenButton.tintOverride == Palette.accent)
        #expect(local.screenButton.label == Strings.sharingScreen)
        let cloud = try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID("cloud")))] as? SectionHeaderRowView)
        #expect(!cloud.showsScreenButton)
        #expect(Self.customAction(cloud, named: Strings.viewScreen) != nil)
        Self.lay(cloud, hovered: true)
        #expect(cloud.showsScreenButton)
        #expect(cloud.screenButton.tintOverride == nil)
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
            #expect(row.hasScreenAction)
            for hovered in [false, true, false] {
                row.isHovered = hovered
                row.needsLayout = true
                row.layoutSubtreeIfNeeded()
                #expect(row.showsScreenButton == hovered, "the screen button draws on hover only")
                #expect(name.frame == nameAtRest, "showing + or the screen button must not move or narrow the machine name")
                #expect(!row.addButton.isHidden, "Add remains visible beside the screen action at rest")
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
            #expect(!row.showsScreenButton)
            #expect(row.screenButton.icon == .remoteDisplay, "Share and View draw a screen, never the share arrow")
            Self.lay(row, hovered: true)
            #expect(row.showsScreenButton)
            #expect(row.screenButton.accessibilityPerformPress())
            #expect(intents.last == expected)
            #expect(!row.screenButtonFrame.intersects(row.chevronFrame))
        }
        let offline = try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID("offline")))] as? SectionHeaderRowView)
        Self.lay(offline, hovered: true)
        #expect(offline.showsScreenButton)
        #expect(!offline.screenButton.accessibilityPerformPress())
        let linux = try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID("linux")))] as? SectionHeaderRowView)
        Self.lay(linux, hovered: true)
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
        let local = [Self.section("local", name: "This Mac", kind: SidebarMachine.Kind.local)]
        #expect(SidebarScreenActions(macs: [:], aliases: [:], sharing: true).applying(to: local)[0].machine?.screenShared == true)
        #expect(SidebarScreenActions(macs: [:], aliases: [:]).applying(to: local)[0].machine?.screenShared == false)
        #expect(result.allSatisfy { $0.machine?.screenShared == false }, "only the local machine carries sharing")

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
        Self.lay(mac, hovered: true)
        #expect(mac.screenButton.accessibilityPerformPress())
        #expect(intents == [.viewScreen(MachineID(routeID))])
        let linux = try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID("linux")))] as? SectionHeaderRowView)
        #expect(!linux.showsScreenButton)
    }
}
