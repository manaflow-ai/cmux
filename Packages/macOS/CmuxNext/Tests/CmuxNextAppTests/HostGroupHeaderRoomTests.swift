import AppKit
@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A remote group's header carries its machine's room (#25121's groups): the room is a field of the
/// header's machine, drawn as the header's second line, with the whole reading on hover and the room
/// read by VoiceOver after the name. The group's chats stay plain rows under it. Another machine's
/// header, and a group without a reading, stay one line.
@MainActor struct HostGroupHeaderRoomTests {
    static let room = SidebarMachine.Room(line: "31 GB free · CPU 12/32", toolTip: "31 GB free · CPU 12/32 · 180 GB disk",
                                          spoken: "31 GB free · CPU 12/32")

    private static func section(room: SidebarMachine.Room?, hostGroup: Bool) -> SidebarSection {
        var machine = SidebarMachine(id: MachineID("huge-blue"), name: "huge-blue", kind: .ssh)
        machine.room = room
        var section = SidebarSection(kind: .machine(machine), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("ws-1"), title: "api", lastActivity: Date())),
        ])
        section.isHostGroup = hostGroup
        return section
    }

    private static func headerHeight(_ section: SidebarSection) -> CGFloat? {
        var options = SidebarLayoutOptions()
        options.flattensMachines = true
        let local = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [])
        return SidebarLayout.make(sections: [local, section], metrics: .standard, options: options).rows
            .first { $0.key == .section(section.id) }?.height
    }

    private static func header(_ section: SidebarSection, height: CGFloat) -> SectionHeaderRowView {
        let row = SidebarRow(key: .section(section.id), y: 0, height: height, section: section.id, workspace: nil, siblingIndex: 0,
                             isLastInGroup: true, isCollapsed: false, childCount: 1)
        let view = SectionHeaderRowView(key: .section(section.id))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        view.configure(section, row: row)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func aRemoteGroupWithARoomIsOneDetailLineTaller() throws {
        let m = SidebarLayoutMetrics.standard
        let tall = try #require(Self.headerHeight(Self.section(room: Self.room, hostGroup: true)))
        #expect(tall == m.sectionHeaderHeight + (m.rowHeightWithSubtitle - m.rowHeight))
        #expect(Self.headerHeight(Self.section(room: nil, hostGroup: true)) == m.sectionHeaderHeight)
    }

    /// The sole machine's header titles the list and draws no room, so its height stays one line.
    @Test func aSoleRemoteGroupTitlingTheListStaysOneLine() throws {
        let section = Self.section(room: Self.room, hostGroup: true)
        let row = try #require(SidebarLayout.make(sections: [section], metrics: .standard, options: SidebarLayoutOptions()).rows
            .first { $0.key == .section(section.id) })
        #expect(row.titlesProjects)
        #expect(row.height == SidebarLayoutMetrics.standard.sectionHeaderHeight)
    }

    @Test func theHeaderDrawsTheRoomUnderTheNameAndSaysIt() throws {
        let section = Self.section(room: Self.room, hostGroup: true)
        let view = Self.header(section, height: try #require(Self.headerHeight(section)))
        #expect(view.shownRoomLine == Self.room.line)
        #expect(view.accessibilityLabel()?.hasSuffix(", " + Self.room.spoken) == true)
        #expect(view.themedToolTip?.contains(Self.room.toolTip) == true)
    }

    @Test func anotherMachinesHeaderIgnoresTheRoom() {
        let view = Self.header(Self.section(room: Self.room, hostGroup: false), height: SidebarLayoutMetrics.standard.sectionHeaderHeight)
        #expect(view.shownRoomLine == nil)
        #expect(view.accessibilityLabel()?.contains(Self.room.spoken) == false)
    }

    @Test func aPeersReadingBecomesItsRoomWithTheWholeReadingOnHover() {
        let roomy = AcpmuxPeerList.Resources(ramFreeGB: 31, coresBusy: 12, cores: 32, diskFreeGB: 180, over: false)
        let room = RemoteMachinesSidebar.room(roomy, name: "huge-blue")
        #expect(room.line == RemoteMachinesStrings.resources(roomy))
        #expect(room.toolTip == RemoteMachinesStrings.named(room.line, RemoteMachinesStrings.diskFree(180)))
        // Low disk is already on the line, so hover adds nothing.
        let tight = AcpmuxPeerList.Resources(ramFreeGB: 2, coresBusy: 12, cores: 12, diskFreeGB: 9, over: true)
        #expect(RemoteMachinesSidebar.room(tight, name: "cmux16").toolTip == RemoteMachinesStrings.resources(tight))
    }
}
