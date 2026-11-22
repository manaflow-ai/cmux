import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextSidebar

/// SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE: a default workspace row is its name,
/// the user's icon and the unread/attention mark, for every kind; every other
/// element shows only when its setting (or the kind's override) turns it on.
@MainActor @Suite struct WorkspaceRowContentTests {
    static let noon = Date(timeIntervalSince1970: 1_790_000_000)

    /// A workspace with every fact present.
    static func full(_ kind: WorkspaceRowKind, id raw: String = "w", activity: StatusIndicatorState = .busy,
                     agentWorking: Bool = false) -> SidebarWorkspace {
        SidebarWorkspace(
            id: WorkspaceID(raw), title: "app", directory: "~/src/app", branch: "main", process: "vim",
            status: "Claude: running tests", ports: ":3000", pullRequest: "#12 ✓", lastActivity: noon,
            rowKind: kind, agentWorking: agentWorking, icon: .emoji("🚀", chip: nil), unread: .count(2),
            activity: activity, progress: SidebarProgress(value: 0.5),
            tabs: [SidebarTab(id: TabID("t1"), title: "zsh"), SidebarTab(id: TabID("t2"), title: "docs", kind: .browser)]
        )
    }

    @Test(arguments: WorkspaceRowKind.allCases)
    func theDefaultRowIsNameIconAndAttentionOnly(kind: WorkspaceRowKind) {
        let content = WorkspaceRowContent(Self.full(kind), preferences: .defaults, now: Self.noon)
        #expect(content.icon == .emoji("🚀", chip: nil))
        #expect(content.detail == nil, "no path, branch, process, status, ports or time")
        #expect(content.tabCount == nil)
        #expect(content.badge == nil)
        #expect(content.progress == nil)
        #expect(content.activity == .idle, "a terminal's busy work is the progress element, off by default")
        #expect(!content.showsWorking)
    }

    @Test(arguments: [StatusIndicatorState.waiting, .error, .success])
    func attentionStatesAlwaysShow(state: StatusIndicatorState) {
        #expect(WorkspaceRowContent(Self.full(.terminal, activity: state), preferences: .defaults).activity == state)
    }

    @Test func aDefaultRowIsOneLineHigh() throws {
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                       nodes: WorkspaceRowKind.allCases.map { .workspace(Self.full($0, id: $0.rawValue)) })]
        let m = SidebarLayoutMetrics.standard
        let rows = SidebarLayout.make(sections: sections, metrics: m).rows
        #expect(rows.count == WorkspaceRowKind.allCases.count)
        #expect(rows.allSatisfy { $0.height == m.rowHeight && $0.detail == nil && $0.tabCount == nil })
    }

    @Test func aDefaultRowViewDrawsOnlyTheName() throws {
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                       nodes: [.workspace(Self.full(.mixed, id: "a"))])]
        let h = MinimalChromeTests.Harness(sections: sections)
        let row = try #require(h.sidebar.list.rowViews[.workspace(WorkspaceID("a"))] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        let texts = row.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
        #expect(texts.isEmpty, "visible texts beside the name: \(texts)")
    }

    @Test func eachElementShowsItsOwnFact() {
        let ws = Self.full(.terminal)
        func content(_ element: WorkspaceRowElement) -> WorkspaceRowContent {
            var preferences = WorkspaceRowPreferences.defaults
            preferences.base.shown.insert(element)
            return WorkspaceRowContent(ws, preferences: preferences, now: Self.noon)
        }
        #expect(content(.directory).detail == "~/src/app")
        #expect(content(.branch).detail == "main")
        #expect(content(.process).detail == "vim")
        #expect(content(.agentStatus).detail == "Claude: running tests")
        #expect(content(.ports).detail == ":3000")
        #expect(content(.lastActivity).detail == WorkspaceRowContent.activityText(Self.noon, now: Self.noon))
        #expect(content(.tabCount).tabCount == 2)
        #expect(content(.pullRequest).badge == "#12 ✓")
        #expect(content(.progress).progress == SidebarProgress(value: 0.5))
        #expect(content(.progress).activity == .busy)
    }

    @Test func turningTheIconOffHidesTheUsersIcon() {
        var preferences = WorkspaceRowPreferences.defaults
        preferences.base.shown.remove(.icon)
        #expect(WorkspaceRowContent(Self.full(.agent), preferences: preferences).icon == nil)
    }

    @Test func theSecondLineFollowsTheChosenOrder() {
        var preferences = WorkspaceRowPreferences.defaults
        preferences.base = WorkspaceRowElements(shown: [.directory, .branch, .ports], secondLineOrder: [.ports, .branch])
        let content = WorkspaceRowContent(Self.full(.terminal), preferences: preferences)
        #expect(content.detail == ":3000 · main · ~/src/app", "listed items first, the rest in the default order")
    }

    @Test func aKindOverrideChangesOnlyThatKind() {
        var preferences = WorkspaceRowPreferences.defaults
        preferences.overrides[.terminal] = WorkspaceRowOverride(elements: [.directory: true, .icon: false])
        preferences.overrides[.mixed] = WorkspaceRowOverride(elements: [.branch: true, .process: true], secondLineOrder: [.process])
        let terminal = WorkspaceRowContent(Self.full(.terminal), preferences: preferences)
        #expect(terminal.detail == "~/src/app")
        #expect(terminal.icon == nil)
        #expect(WorkspaceRowContent(Self.full(.mixed), preferences: preferences).detail == "vim · main")
        let agent = WorkspaceRowContent(Self.full(.agent), preferences: preferences)
        #expect(agent.detail == nil && agent.icon != nil)
    }

    /// The working-indicator slot: an agent turn shows (as the busy glyph for
    /// now) while `working` is on, which it is by default.
    @Test func anAgentTurnFillsTheWorkingSlot() {
        let working = WorkspaceRowContent(Self.full(.agent, agentWorking: true), preferences: .defaults)
        #expect(working.showsWorking)
        #expect(working.activity == .busy)
        var off = WorkspaceRowPreferences.defaults
        off.base.shown.remove(.working)
        let hidden = WorkspaceRowContent(Self.full(.agent, agentWorking: true), preferences: off)
        #expect(!hidden.showsWorking)
        #expect(hidden.activity == .idle)
    }

    @Test func lastActivityShowsATimeTodayAndADateBefore() {
        let calendar = Calendar(identifier: .gregorian)
        let today = WorkspaceRowContent.activityText(Self.noon, now: Self.noon, calendar: calendar)
        let earlier = WorkspaceRowContent.activityText(Self.noon.addingTimeInterval(-3 * 86_400), now: Self.noon, calendar: calendar)
        #expect(today == Self.noon.formatted(date: .omitted, time: .shortened))
        #expect(earlier != today)
        #expect(earlier == Self.noon.addingTimeInterval(-3 * 86_400).formatted(.dateTime.month(.abbreviated).day()))
    }

    @Test func theModelPassesRowPreferencesToTheLayout() {
        let model = SidebarModel(sections: [])
        var preferences = SidebarSectionsPreferences.defaults
        preferences.workspaceRow.overrides[.browser] = WorkspaceRowOverride(elements: [.directory: true])
        model.applyListPreferences(preferences)
        #expect(model.listOptions().workspaceRow == preferences.workspaceRow)
    }
}
