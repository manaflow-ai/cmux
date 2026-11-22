import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A group header's icons are its member rows' size (Leo 2026-11-02: "the sizes of the icons for groups and workspaces
/// aren't the same size anymore they should be"): a group's own icon takes the workspace icon's frame and glyph, and a
/// remote group's machine mark takes a row's trailing mark size, at each density and text size.
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

    /// The remote group's machine mark sits in the trailing column at a status mark's size, the size every row's trailing
    /// mark takes (the spinner's, the warning triangle's), never the larger leading glyph's.
    @Test(arguments: cases)
    func aRemoteGroupsMachineMarkIsARowMarksSize(_ c: Case) throws {
        try Self.with(c) {
            let list = Self.sidebar().list
            let header = try Self.laidOut(list, .group(SidebarGroup.hostGroupID(Self.remote.id)), as: GroupHeaderRowView.self)
            try #require(!header.machineMark.isHidden, "the remote group draws its machine mark")
            let side = SidebarStyle.statusGlyphSize
            #expect(header.machineMark.frame.size == NSSize(width: side, height: side),
                    "group mark box \(header.machineMark.frame.size), a row's trailing mark \(side)")
            // The image itself rasters at the icon floor (12 pt) and scales into this box, as the rows' marks do.
            #expect(abs(header.machineMark.frame.midY - header.bounds.midY) < 0.5, "the group's mark centers on its bar")
        }
    }
}
