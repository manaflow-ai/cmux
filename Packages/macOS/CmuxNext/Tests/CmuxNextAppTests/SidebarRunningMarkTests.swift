import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-18: a running row gets its running mark on the left (the Orbit set's dots,
/// `OrbitStatusIconSetTests`), on workspace rows and on the session rows listed under them. Leo
/// and Lawrence's team call (2026-10-14) and Leo 2026-10-15 (#20900): one status icon per row, the
/// row's most urgent state, on the side Debug Settings `sidebar.statusIconSide` names, in a fixed
/// slot so titles line up whether a row has a state or not; no corner badge and no count number.
@MainActor @Suite(.serialized) struct SidebarRunningMarkTests {
    private static let failing = WorkspaceID("ws-mark-failing")
    private static let done = WorkspaceID("ws-mark-done")
    private static let quiet = WorkspaceID("ws-mark-quiet")
    private static let agent = WorkspaceID("ws-mark-agent")
    private static let runningTab = TabID("tab-running")
    private static let quietTab = TabID("tab-quiet")

    @Test func theStatusIconOnTheLeftIsTheDefaultAndDebugSettingsListsTheSide() {
        #expect(SidebarRowBadgeStyle.tunable.defaultValue == .status)
        #expect(SidebarStatusIconSide.tunable.defaultValue == .left)
        #expect(SidebarTunables.all.map(\.key).contains(SidebarStatusIconSide.tunable.key))
    }

    @Test func aWorkingAgentRowDrawsItsMarkBeforeTheTitle() throws {
        try Self.withSide(nil) {
            let row = try Self.row(Self.sidebar(), Self.agent)
            #expect(row.statusSide == .left)
            #expect(row.activity.state == .working)
            #expect(!row.activity.isHidden && row.activity.frame.width > 0)
            let title = row.title.frame.minX + WorkspaceRowView.labelInset
            #expect(row.activity.frame.maxX <= title, "the mark \(row.activity.frame) sits before the title at \(title)")
            #expect(row.activity.frame.minX >= SidebarStyle.horizontalInset - 0.5)
            #expect(row.rowBadge.states.isEmpty, "no corner badge")
        }
    }

    @Test func titlesLineUpWithOrWithoutAMark() throws {
        try Self.withSide(.left) {
            let sidebar = Self.sidebar()
            let quiet = try Self.row(sidebar, Self.quiet)
            for id in [Self.agent, Self.failing, Self.done] {
                #expect(abs(try Self.row(sidebar, id).title.frame.minX - quiet.title.frame.minX) < 0.5, "\(id)")
            }
        }
    }

    @Test(arguments: [SidebarStatusIconSide.left, .right])
    func aRowShowsItsMostUrgentStateOnTheSettingsSide(_ side: SidebarStatusIconSide) throws {
        try Self.withSide(side) {
            let row = try Self.row(Self.sidebar(), Self.failing)
            #expect(row.activity.state == .error, "an error outranks unread: \(row.activity.state)")
            #expect(row.badge.isHidden, "no count number")
            switch side {
            case .left: #expect(row.activity.frame.maxX <= row.title.frame.minX + WorkspaceRowView.labelInset)
            case .right: #expect(row.activity.frame.minX > row.layoutBounds.midX)
            }
        }
    }

    @Test func unreadWorkShowsTheDoneMark() throws {
        try Self.withSide(.left) {
            let row = try Self.row(Self.sidebar(), Self.done)
            #expect(row.activity.state == .success)
            #expect(row.badge.isHidden)
        }
    }

    @Test(arguments: [SidebarStatusIconSide.left, .right])
    func aSessionRowDrawsItsRunningMarkOnTheSameSide(_ side: SidebarStatusIconSide) throws {
        try Self.withSide(side) {
            let sidebar = Self.sidebar()
            let running = try Self.tabRow(sidebar, Self.runningTab), quiet = try Self.tabRow(sidebar, Self.quietTab)
            #expect(running.activity.state == .working)
            #expect(running.activity.frame.width > 0)
            #expect(quiet.activity.state == .idle)
            #expect(abs(running.title.frame.minX - quiet.title.frame.minX) < 0.5, "a session's mark moves no title")
            switch side {
            case .left: #expect(running.activity.frame.maxX <= running.title.frame.minX + SidebarStyle.labelCellPadding)
            case .right: #expect(running.activity.frame.minX > running.layoutBounds.midX)
            }
        }
    }

    // MARK: Fixtures

    /// Runs `body` with the Status icon row badge on `side` (nil: the defaults). The store is
    /// active without a file, so nothing is written; the tunables watch is refreshed right away,
    /// as the app does one main-actor hop later.
    private static func withSide(_ side: SidebarStatusIconSide?, _ body: () throws -> Void) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let style = SidebarRowBadgeStyle.tunable.key, sideKey = SidebarStatusIconSide.tunable.key
        TunableStore.shared.set(style, nil)
        TunableStore.shared.set(sideKey, side?.tunableValue)
        SidebarTunablesWatch.shared.changed()
        defer {
            TunableStore.shared.set(sideKey, nil)
            SidebarTunablesWatch.shared.changed()
        }
        try body()
    }

    /// A failing row with unread items, a row with unread done work, a quiet row, and a working
    /// agent row listing a running session and a quiet one.
    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let tabs = [SidebarTab(id: runningTab, title: "fix the build", kind: .agentChat, activity: .working),
                    SidebarTab(id: quietTab, title: "zsh", kind: .terminal)]
        let rows = [
            SidebarWorkspace(id: failing, title: "api", kind: .terminal, unread: .count(2), activity: .error),
            SidebarWorkspace(id: done, title: "web", kind: .terminal, unread: .count(1)),
            SidebarWorkspace(id: quiet, title: "docs", kind: .terminal),
            SidebarWorkspace(id: agent, title: "cmux-next", agentWorking: true, kind: .harness, activity: .working, tabs: tabs),
        ]
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })])
        let design = DesignSettings()
        design.sidebarSections.showWorkspaceTabs = true
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
    }

    private static func tabRow(_ sidebar: SidebarView, _ id: TabID) throws -> SidebarTabRowView {
        try #require(sidebar.list.rowViews[.tab(agent, id)] as? SidebarTabRowView)
    }
}
