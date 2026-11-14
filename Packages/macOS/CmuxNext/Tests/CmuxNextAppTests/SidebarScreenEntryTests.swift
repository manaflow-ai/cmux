import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextSidebarActions
import Testing

/// Screen Sharing from the sidebar's machine headers (Leo: "for screensharing, jf theres no easy path to use
/// it then theres no point even if its the most performant thing in the world"): This Mac's header shows
/// Share, a Cloud machine's View screen, an SSH or server machine's nothing; each routes to its action.
@MainActor @Suite(.serialized) struct SidebarScreenEntryTests {
    static func section(_ id: String, name: String, kind: SidebarMachine.Kind) -> SidebarSection {
        SidebarSection(kind: .machine(SidebarMachine(id: MachineID(id), name: name, kind: kind)),
                       nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-" + id), title: "A project with a long descriptive title",
                                                           directory: "~/Projects"))])
    }

    static var examples: [SidebarSection] {
        [section("local", name: "This Mac", kind: .local),
         section("cloud", name: "Cloud development environment with a long name", kind: .cloud),
         section("ssh", name: "Linux SSH build machine", kind: .ssh),
         section("server", name: "A very long Mac Studio device name", kind: .server)]
    }

    static func groupedList(_ sections: [SidebarSection], width: Double = 300) -> (SidebarListView, SidebarModel) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections)
        model.groupsByComputer = true
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        return (list, model)
    }

    static func header(_ list: SidebarListView, _ id: String) throws -> SectionHeaderRowView {
        try #require(list.rowViews[SidebarRowKey.section(SectionID.machine(MachineID(id)))] as? SectionHeaderRowView)
    }

    // MARK: Routing

    @Test func viewScreenOpensOnlyACloudMachinesDesktopAsThePersonsGesture() {
        var performed: [(ActionID, ActionInvocation)] = []
        let actions = SidebarIntentActions(perform: { performed.append(($0, $1)) }, sharesDirectly: { true })
        for id in ["local", "ssh", "server", "missing", "cloud"] {
            actions.handle(.viewScreen(MachineID(id)), sections: Self.examples)
        }
        #expect(performed.map(\.0) == ["cloudOpenDesktop"])
        #expect(performed.first?.1.target == ActionTargetRef(kind: .machine, id: "cloud"))
        #expect(performed.first?.1.origin == .user)
    }

    @Test func shareSharesThisMacDirectlyOnlyWhereThatCanFinishTheJobElseOpensScreenSharing() {
        var performed: [(ActionID, ActionInvocation)] = []
        var direct = true
        let actions = SidebarIntentActions(perform: { performed.append(($0, $1)) }, sharesDirectly: { direct })
        for id in ["cloud", "ssh", "server", "missing"] {
            actions.handle(.shareScreen(MachineID(id)), sections: Self.examples)
        }
        #expect(performed.isEmpty, "a remote machine's header cannot share this Mac")
        actions.handle(.shareScreen(.local), sections: Self.examples)
        // A build without cmux Remote (Release, NIGHTLY), or signed out: the guided Allow Mac Screen flow.
        direct = false
        actions.handle(.shareScreen(.local), sections: Self.examples)
        #expect(performed.map(\.0) == ["macScreen.shareThisMac", "macScreen.open"])
        #expect(performed.allSatisfy { $0.1.origin == .user && $0.1.target == nil })
    }

    @Test func theSpaceBarsActionIntentsKeepTheirActions() {
        var performed: [(ActionID, ActionInvocation)] = []
        let actions = SidebarIntentActions(perform: { performed.append(($0, $1)) }, sharesDirectly: { false })
        actions.handle(.newProfile, sections: [])
        actions.handle(.openProfileInNewWindow(ProfileKey("work")), sections: [])
        #expect(performed.map(\.0) == ["space.new", "space.openInNewWindow"])
        #expect(performed.last?.1.target == ActionTargetRef(kind: .profile, id: "work"))
        #expect(performed.allSatisfy { $0.1.origin == .user })
    }

    // MARK: Headers

    @Test func onlyThisMacAndCloudHeadersShowAScreenButtonAndItSendsTheirIntent() throws {
        let (list, model) = Self.groupedList(Self.examples)
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        let local = try Self.header(list, "local")
        #expect(local.showsScreenButton)
        #expect(local.screenButton.label == Strings.shareScreen)
        #expect(local.screenButton.accessibilityPerformPress())
        let cloud = try Self.header(list, "cloud")
        #expect(cloud.showsScreenButton)
        #expect(cloud.screenButton.label == Strings.viewScreen)
        #expect(cloud.screenButton.accessibilityPerformPress())
        for id in ["ssh", "server"] {
            let header = try Self.header(list, id)
            #expect(!header.showsScreenButton, "\(id) has no screen path in this slice")
            #expect(!header.screenButton.accessibilityPerformPress())
        }
        #expect(intents == [.shareScreen(.local), .viewScreen(MachineID("cloud"))])
    }

    @Test func aReusedHeaderDropsTheScreenButtonWhenItsMachineHasNone() throws {
        let (list, model) = Self.groupedList(Self.examples)
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        #expect(try Self.header(list, "cloud").showsScreenButton)
        model.sections = [Self.examples[0], Self.section("cloud", name: "Now an SSH machine", kind: .ssh)]
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let reused = try Self.header(list, "cloud")
        #expect(reused.screenAction == nil)
        #expect(!reused.showsScreenButton)
        #expect(!reused.screenButton.accessibilityPerformPress())
        #expect(intents.isEmpty)
    }

    @Test func theSoleMachinesProjectsHeaderStillOffersShare() throws {
        let (list, model) = Self.groupedList([Self.examples[0]])
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        // The list always draws the sole machine's header, titled "Projects" (`showsSoleMachineHeader`).
        let local = try Self.header(list, "local")
        #expect(local.showsScreenButton)
        #expect(local.screenButton.accessibilityPerformPress())
        #expect(intents == [.shareScreen(.local)])
    }

    @Test(arguments: [240.0, 300.0, 360.0])
    func headerControlsNeverOverlapTheNameOrEachOther(width: Double) throws {
        let (list, _) = Self.groupedList(Self.examples, width: width)
        for id in ["local", "cloud"] {
            let row = try Self.header(list, id)
            #expect(row.allowsAdd)
            #expect(row.showsChevron)
            #expect(row.showsScreenButton)
            #expect(!row.addButton.isHidden, "the + stays at rest beside the screen button")
            let name = try #require(row.subviews.compactMap { $0 as? ChromeLabel }.first { !$0.isHidden && !$0.stringValue.isEmpty })
            #expect(name.frame.width >= 2 * SidebarStyle.controlSize, "the machine name keeps usable width at \(width)")
            let controls = [row.screenButton.frame, row.chevronFrame, row.addButton.frame]
            for frame in controls { #expect(name.frame.maxX <= frame.minX) }
            #expect(!row.screenButton.frame.intersects(row.chevronFrame))
            #expect(!row.screenButton.frame.intersects(row.addButton.frame))
            #expect(!row.chevronFrame.intersects(row.addButton.frame))
            #expect(row.chevronFrame.maxX <= row.screenButton.frame.minX && row.screenButton.frame.maxX <= row.addButton.frame.minX,
                    "from the trailing edge: +, screen, chevron")
        }
    }
}
