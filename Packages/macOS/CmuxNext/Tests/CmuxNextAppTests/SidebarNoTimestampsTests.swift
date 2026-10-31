import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-19: "By default in the sidebar, we should never show timestamps, like how long
/// something took." A workspace row draws no clock time, age ("3d") or time since its last change
/// on any row style or density unless the user turns on `sidebar.showTimestamps`. A one-line
/// status (not a time) still reads on the name's line, and the Last Activity row element, when
/// the user picks it, still shows. The hover card is not the row and keeps its times.
@MainActor @Suite(.serialized) struct SidebarNoTimestampsTests {
    private static let recent = WorkspaceID("ws-recent")
    private static let old = WorkspaceID("ws-old")
    private static let status = WorkspaceID("ws-status")

    private static func sidebar(style: SidebarRowBadgeStyle?, density: SidebarDensity = .compact,
                                showTimestamps: Bool? = nil, lastActivityElement: Bool = false,
                                agentStatusElement: Bool = false) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let now = Date()
        let recentRow = SidebarWorkspace(id: recent, title: "cmux-next", lastActivity: now.addingTimeInterval(-180),
                                         kind: .terminal, unread: .count(1))
        let oldRow = SidebarWorkspace(id: old, title: "api", lastActivity: now.addingTimeInterval(-5 * 86_400),
                                      kind: .terminal, activity: .success)
        var statusRow = SidebarWorkspace(id: status, title: "build", lastActivity: now.addingTimeInterval(-60), kind: .terminal)
        statusRow.status = "Building"
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(recentRow), .workspace(oldRow), .workspace(statusRow)]),
        ])
        model.rowBadgeStyle = style
        let design = DesignSettings()
        design.sidebarSections.density = density
        if let showTimestamps { design.sidebarSections.showTimestamps = showTimestamps }
        if lastActivityElement { design.sidebarSections.workspaceRow.base.shown.insert(.lastActivity) }
        if agentStatusElement { design.sidebarSections.workspaceRow.base.shown.insert(.agentStatus) }
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

    /// The text a row draws on the right of its name's line, or nil.
    private static func trailing(_ row: WorkspaceRowView) -> String? {
        row.timeLabel.isHidden || row.timeLabel.stringValue.isEmpty ? nil : row.timeLabel.stringValue
    }

    nonisolated struct Look: Sendable, CustomTestStringConvertible {
        var style: SidebarRowBadgeStyle?
        var density: SidebarDensity
        var testDescription: String { "\(style.map { "\($0)" } ?? "default style") \(density)" }
    }

    nonisolated static let looks: [Look] = [
        Look(style: nil, density: .compact), Look(style: .corner, density: .compact), Look(style: .stack, density: .compact),
        Look(style: .trailing, density: .compact), Look(style: .corner, density: .comfortable),
        Look(style: nil, density: .expanded), Look(style: .corner, density: .expanded),
    ]

    @Test func offByDefault() {
        #expect(SidebarSectionsPreferences.defaults.showTimestamps == false)
    }

    @Test(arguments: looks)
    func rowsDrawNoTimeByDefault(_ look: Look) throws {
        let sidebar = Self.sidebar(style: look.style, density: look.density)
        for id in [Self.recent, Self.old] {
            let row = try Self.row(sidebar, id)
            #expect(Self.trailing(row) == nil, "\(id): a time draws on the right: \(Self.trailing(row) ?? "")")
            #expect(!row.subtitle.stringValue.contains(":"), "\(id): a clock time in the second line: \(row.subtitle.stringValue)")
        }
    }

    @Test(arguments: [Look(style: .corner, density: .compact), Look(style: .corner, density: .expanded)])
    func theSettingBringsTheTimesBack(_ look: Look) throws {
        let sidebar = Self.sidebar(style: look.style, density: look.density, showTimestamps: true)
        for id in [Self.recent, Self.old] {
            #expect(Self.trailing(try Self.row(sidebar, id)) != nil, "\(id): no time with sidebar.showTimestamps on")
        }
    }

    /// A one-line status (opt-in since Lawrence 2026-10-21) is the row's state, not a time: with
    /// the Agent Status element on it stays on the name's line.
    @Test func aOneLineStatusStillReadsOnTheNamesLine() throws {
        let sidebar = Self.sidebar(style: .corner, agentStatusElement: true)
        #expect(Self.trailing(try Self.row(sidebar, Self.status)) == "Building")
    }

    /// The Last Activity element is the user's explicit pick in Settings > Workspace Row: it shows.
    @Test func thePickedLastActivityElementStillShows() throws {
        let sidebar = Self.sidebar(style: .corner, lastActivityElement: true)
        #expect(!(try Self.row(sidebar, Self.recent)).subtitle.stringValue.isEmpty)
    }
}
