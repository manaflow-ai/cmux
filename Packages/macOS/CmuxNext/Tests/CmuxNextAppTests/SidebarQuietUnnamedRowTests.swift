import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-20: rows like "~", "workspace-11" and "workspace-29" (workspaces nobody named, with
/// nothing that names them) clutter the sidebar. Such a row reads quiet: its name in the secondary
/// ink while it is idle, read and not selected, so the named work stands out. Nothing hides or
/// closes, and any activity, unread mark, selection or hover brings the full ink back.
@MainActor @Suite(.serialized) struct SidebarQuietUnnamedRowTests {
    private static func model(name: String, title: String? = nil) throws -> WorkspaceModel {
        var object: [String: Any] = ["id": 1, "key": "k-\(name)", "name": name, "screens": []]
        if let title { object["title"] = title }
        let data = try JSONSerialization.data(withJSONObject: object)
        return WorkspaceModel(try JSONDecoder().decode(WorkspaceSnapshot.self, from: data))
    }

    @Test func aDefaultNameOrABareHomeFolderSaysNothing() throws {
        let unnamed = try Self.model(name: "workspace-11")
        #expect(SidebarMapping.isUnnamed(unnamed, label: nil), "the daemon's default name")
        #expect(SidebarMapping.isUnnamed(unnamed, label: "~"), "a terminal in the home folder")
        #expect(!SidebarMapping.isUnnamed(unnamed, label: "cmux-next"), "a name from its front tab")
        #expect(!SidebarMapping.isUnnamed(try Self.model(name: "api"), label: nil), "a name the user gave")
        #expect(!SidebarMapping.isUnnamed(try Self.model(name: "workspace-11", title: "Deploy"), label: nil), "a title the user gave")
    }

    private static func sidebar(_ rows: [SidebarWorkspace], selected: WorkspaceID? = nil) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })],
                                 activeWorkspaceID: selected)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded(); $0.updateLayer() }
        return sidebar
    }

    private static func ink(_ sidebar: SidebarView, _ id: String) throws -> NSColor? {
        let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID(id))] as? WorkspaceRowView)
        var color: NSColor?
        row.performWithTheme { color = row.title.textColor }
        return color
    }

    private static func expected(_ sidebar: SidebarView, _ id: String, secondary: Bool) throws -> NSColor {
        let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID(id))] as? WorkspaceRowView)
        var color = NSColor.clear
        row.performWithTheme { color = secondary ? Palette.textSecondary : Palette.textPrimary }
        return color
    }

    @Test func anIdleUnnamedRowReadsQuietAndActivityBringsItBack() throws {
        var quiet = SidebarWorkspace(id: WorkspaceID("ws-quiet"), title: "workspace-11", kind: .terminal)
        quiet.isUnnamed = true
        var unread = SidebarWorkspace(id: WorkspaceID("ws-unread"), title: "workspace-12", kind: .terminal, unread: .dot)
        unread.isUnnamed = true
        var working = SidebarWorkspace(id: WorkspaceID("ws-working"), title: "~", kind: .terminal, activity: .working)
        working.isUnnamed = true
        var chosen = SidebarWorkspace(id: WorkspaceID("ws-chosen"), title: "workspace-29", kind: .terminal)
        chosen.isUnnamed = true
        let named = SidebarWorkspace(id: WorkspaceID("ws-named"), title: "cmux-next", kind: .terminal)
        let sidebar = Self.sidebar([quiet, unread, working, chosen, named], selected: WorkspaceID("ws-chosen"))
        #expect(try Self.ink(sidebar, "ws-quiet") == Self.expected(sidebar, "ws-quiet", secondary: true), "an idle unnamed row keeps the full ink")
        for id in ["ws-unread", "ws-working", "ws-chosen", "ws-named"] {
            #expect(try Self.ink(sidebar, id) == Self.expected(sidebar, id, secondary: false), "\(id) reads quiet")
        }
    }
}
