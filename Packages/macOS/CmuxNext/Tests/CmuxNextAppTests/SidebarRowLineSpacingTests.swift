import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-20: rows with a second line ("a2 · Fix chat composer buttons" over "Chief") and
/// one-line rows have inconsistent spacing. A row's text keeps the same room above its first line
/// and below its last, whether it has one line or two, at every density, so a list that mixes
/// them reads in one rhythm.
@MainActor @Suite(.serialized) struct SidebarRowLineSpacingTests {
    private static let single = WorkspaceID("ws-single")
    private static let double = WorkspaceID("ws-double")

    private static func sidebar(density: SidebarDensity) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let one = SidebarWorkspace(id: single, title: "cmux-next", kind: .terminal)
        // A second line is only what the person turned on (Leo 2026-10-30: "remove the second line"): the folder here.
        let two = SidebarWorkspace(id: double, title: "a2 · Fix chat composer buttons", directory: "~/code/app", kind: .terminal)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(one), .workspace(two)]),
        ])
        let design = DesignSettings()
        design.sidebarSections.density = density
        // The sidebar renders the design's row preferences into its model (`applyListPreferences`).
        design.sidebarSections.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: WorkspaceRowElements.standard.shown.union([.directory])))
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
    }

    /// The room above the row's first text line and below its last, in the row's own top-down y.
    private static func padding(_ row: WorkspaceRowView) -> (top: CGFloat, bottom: CGFloat) {
        let lines = [row.title, row.subtitle].filter { !$0.isHidden }
        let frames = lines.map { row.convert($0.frame, from: $0.superview) }
        let height = row.bounds.height
        let top = frames.map { row.isFlipped ? $0.minY : height - $0.maxY }.min() ?? 0
        let bottom = frames.map { row.isFlipped ? height - $0.maxY : $0.minY }.min() ?? 0
        return (top, bottom)
    }

    @Test(arguments: [SidebarDensity.compact, .comfortable])
    func aSecondLineKeepsTheRowsRoomAboveAndBelow(_ density: SidebarDensity) throws {
        let sidebar = Self.sidebar(density: density)
        let one = try Self.row(sidebar, Self.single), two = try Self.row(sidebar, Self.double)
        try #require(!two.subtitle.isHidden, "the row with its folder turned on shows no second line")
        try #require(one.subtitle.isHidden, "the plain row shows a second line")
        let a = Self.padding(one), b = Self.padding(two)
        #expect(abs(a.top - b.top) <= 1, "\(density): \(a.top) pt above a one-line row's text, \(b.top) pt above a two-line row's")
        #expect(abs(a.bottom - b.bottom) <= 1,
                "\(density): \(a.bottom) pt below a one-line row's text, \(b.bottom) pt below a two-line row's")
    }
}
