import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A group header's icons are its member rows' size (Leo 2026-11-02: "the sizes of the icons for groups and workspaces
/// aren't the same size anymore they should be"): a group's own icon takes the workspace icon's frame and glyph, and a
/// remote group's machine mark takes its rows' machine mark size and image, at each density and text size.
@MainActor @Suite(.serialized) struct SidebarGroupIconSizeTests {
    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        var comfortable: Bool
        var textSize: SidebarTextSize
        var testDescription: String { "\(comfortable ? "comfortable" : "compact"), text \(textSize.rawValue)" }
    }

    nonisolated static let cases: [Case] = [false, true].flatMap { c in SidebarTextSize.allCases.map { Case(comfortable: c, textSize: $0) } }

    private static let remote = SidebarMachine(id: MachineID("ssh-cosmic"), name: "cosmic-gray", kind: .ssh)
    private static let icon = WorkspaceIcon.symbol("star.fill", tint: nil)

    private static func sidebar() -> SidebarView {
        let local = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .group(SidebarGroup(id: GroupID("g-local"), name: "Local", icon: icon,
                                workspaces: [SidebarWorkspace(id: WorkspaceID("w-local"), title: "local", icon: icon)])),
        ])
        var host = SidebarSection(kind: .machine(remote), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("w-remote"), machineID: remote.id, title: "remote")),
        ])
        host.isHostGroup = true
        let model = SidebarModel(sections: [local, host.wrappedAsHostGroup()])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return sidebar
    }

    private static func with(_ c: Case, _ body: () throws -> Void) rethrows {
        let density = DesignSettings.shared.sidebarSections.density, text = DesignSettings.shared.sidebarSections.textSize
        DesignSettings.shared.sidebarSections.density = c.comfortable ? .comfortable : .compact
        DesignSettings.shared.sidebarSections.textSize = c.textSize
        defer {
            DesignSettings.shared.sidebarSections.density = density
            DesignSettings.shared.sidebarSections.textSize = text
        }
        try body()
    }

    private static func laidOut<T: NSView>(_ list: SidebarListView, _ key: SidebarRowKey, as _: T.Type) throws -> T {
        let view = try #require(list.rowViews[key] as? T, "no \(T.self) for \(key)")
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test(arguments: cases)
    func aGroupsIconIsItsRowsIconsSize(_ c: Case) throws {
        try Self.with(c) {
            let list = Self.sidebar().list
            let header = try Self.laidOut(list, .group(GroupID("g-local")), as: GroupHeaderRowView.self)
            let row = try Self.laidOut(list, .workspace(WorkspaceID("w-local")), as: WorkspaceRowView.self)
            try #require(!header.glyph.isHidden && !row.icon.isHidden, "both draw their icon")
            #expect(header.glyph.frame.size == row.icon.frame.size, "group icon box \(header.glyph.frame.size), row icon box \(row.icon.frame.size)")
            #expect(header.glyph.frame.size.width == SidebarStyle.iconColumnBox)
        }
    }

    @Test(arguments: cases)
    func aRemoteGroupsMachineMarkIsItsRowsSize(_ c: Case) throws {
        try Self.with(c) {
            let list = Self.sidebar().list
            let header = try Self.laidOut(list, .group(SidebarGroup.hostGroupID(Self.remote.id)), as: GroupHeaderRowView.self)
            let row = try Self.laidOut(list, .workspace(WorkspaceID("w-remote")), as: WorkspaceRowView.self)
            try #require(!header.machineMark.isHidden && !row.machineMark.isHidden, "both draw the machine mark")
            #expect(header.machineMark.frame.size == row.machineMark.frame.size,
                    "group mark box \(header.machineMark.frame.size), row mark box \(row.machineMark.frame.size)")
            #expect(header.machineMark.image?.size == row.machineMark.image?.size,
                    "group mark glyph \(String(describing: header.machineMark.image?.size)), row \(String(describing: row.machineMark.image?.size))")
            #expect(abs(header.machineMark.frame.midY - header.bounds.midY) < 0.5, "the group's mark centers on its bar")
        }
    }
}
