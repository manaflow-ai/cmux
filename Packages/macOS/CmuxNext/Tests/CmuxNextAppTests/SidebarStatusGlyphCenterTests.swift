import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-14 on #20410's capture: "wait that's not centered? why is it superscript?" The
/// status glyph sat on the title's capitals while the count badge sat on the row's middle, so on a
/// two-line row the glyph rode above the badge. Both now center on one line: the middle of the
/// whole row, one line or two.
@MainActor @Suite(.serialized) struct SidebarStatusGlyphCenterTests {
    private static let oneLine = WorkspaceID("ws-one-line")
    private static let twoLines = WorkspaceID("ws-two-lines")

    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let plain = SidebarWorkspace(id: oneLine, title: "cmux-next", unread: .count(1), activity: .success)
        var noted = SidebarWorkspace(id: twoLines, title: "api", unread: .count(2), activity: .waiting(kind: .question))
        noted.status = "Which branch should I use?"
        noted.directory = "~/code/api"
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(plain), .workspace(noted)]),
        ])
        // The count badge and the trailing glyph: the row badge style before the corner badge.
        model.rowBadgeStyle = .trailing
        // The folder on: a one-line status alone sits on the name's line, so the second line is the folder and status.
        model.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: WorkspaceRowElements.standard.shown.union([.directory])))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func marks(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> (row: WorkspaceRowView, glyph: NSRect, badge: NSRect) {
        let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        let glyph = try #require(row.subviews.lazy.compactMap { $0 as? StatusIndicatorView }.first { !$0.isHidden })
        let badge = try #require(row.subviews.lazy.compactMap { $0 as? UnreadBadgeView }.first { !$0.isHidden })
        return (row, glyph.frame, badge.frame)
    }

    @Test func theGlyphAndTheBadgeCenterOnTheRowsMiddleOnOneAndTwoLineRows() throws {
        let sidebar = Self.sidebar()
        for id in [Self.oneLine, Self.twoLines] {
            let (row, glyph, badge) = try Self.marks(sidebar, id)
            let middle = row.bounds.midY
            #expect(abs(glyph.midY - middle) <= 0.5, "\(id): glyph \(glyph.midY), row middle \(middle)")
            #expect(abs(badge.midY - middle) <= 0.5, "\(id): badge \(badge.midY), row middle \(middle)")
        }
        let two = try Self.marks(sidebar, Self.twoLines).row
        #expect(!two.subtitle.isHidden && !two.subtitle.stringValue.isEmpty, "the second row draws its folder and status line")
    }
}
