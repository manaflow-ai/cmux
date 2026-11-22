import AppKit
import Testing
@testable import CmuxNextSidebar

/// WORKSPACE-ROWS-NO-DEFAULT-ICON (Lawrence 2026-10-06: "workspaces by
/// default should NOT have an icon"): a workspace row draws no leading icon
/// unless the user set a custom icon or emoji; its title then starts at the
/// row's leading inset. A custom icon still draws.
@MainActor @Suite struct WorkspaceRowNoDefaultIconTests {
    func row(_ workspace: SidebarWorkspace) throws -> WorkspaceRowView {
        let section = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)),
                                     nodes: [.workspace(workspace)])
        let view = SidebarView(model: SidebarModel(sections: [section]))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        view.layoutSubtreeIfNeeded()
        view.list.reload(animated: false)
        let row = try #require(view.list.rowViews[.workspace(workspace.id)] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        return row
    }

    @Test func aDefaultWorkspaceRowDrawsNoIcon() throws {
        let row = try row(SidebarWorkspace(id: id("plain"), title: "plain"))
        #expect(row.icon.isHidden || row.icon.frame.width == 0, "no kind icon: \(row.icon.frame)")
        #expect(row.title.frame.minX < SidebarStyle.horizontalInset + SidebarStyle.iconBox,
                "the title takes the icon's place: \(row.title.frame.minX)")
    }

    @Test func aCustomIconStillDraws() throws {
        let row = try row(SidebarWorkspace(id: id("rocket"), title: "rocket", icon: .emoji("🚀")))
        #expect(!row.icon.isHidden)
        #expect(row.icon.frame.width > 0)
        #expect(row.icon.emojiText == "🚀")
    }
}
