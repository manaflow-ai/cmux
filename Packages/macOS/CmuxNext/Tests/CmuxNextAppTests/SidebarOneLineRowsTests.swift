import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Compact rows are one line by default (Leo 2026-10-14: "why is it even 2 lines in the first
/// place?"). #19862 drew an unread notification's text under the row by default; the status
/// glyph now carries the state, and the text reads in the row's hover card.
/// `sidebar.workspaceRow.notification` turns the classic second line back on.
@MainActor
struct SidebarOneLineRowsTests {
    private static let notified = WorkspaceID("ws-notified")
    private static let text = "Claude finished: tests pass"

    private static var workspace: SidebarWorkspace {
        var workspace = SidebarWorkspace(id: notified, title: "cmux-next", unread: .count(1), activity: .success)
        workspace.notificationText = text
        return workspace
    }

    private static func sidebar(_ rows: WorkspaceRowPreferences = .defaults) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(workspace)])])
        model.workspaceRow = rows
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    @Test func aNotifiedRowStaysOneLineAndItsHoverCardSaysTheText() throws {
        let row = try #require(Self.sidebar().list.displayed.row(for: .workspace(Self.notified)))
        #expect(row.height == SidebarLayoutMetrics.standard.rowHeight)
        #expect(row.content?.detail == nil)
        let card = WorkspaceHoverCardContent.make(Self.workspace, machine: nil, now: Date())
        #expect(card.facts.contains { $0.text == Self.text })
    }

    @Test func theNotificationSettingBringsTheSecondLineBack() throws {
        var rows = WorkspaceRowPreferences.defaults
        rows.base.shown.insert(.notification)
        let row = try #require(Self.sidebar(rows).list.displayed.row(for: .workspace(Self.notified)))
        #expect(row.height > SidebarLayoutMetrics.standard.rowHeight)
        #expect(row.content?.detail == Self.text)
    }
}
