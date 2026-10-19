import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-18: "everything should either just be 'it is working' or 'it is blue and ready
/// for me to look at it'", with finer icons as an opt-in (`sidebar.detailedStatusIcons`). By default
/// a workspace row's badge is Working (the one spinner) or Ready (the blue dot); a question, a
/// permission request, an error and a finished run are all Ready, so no chat bubble or shield draws.
@MainActor @Suite(.serialized) struct SidebarStatusSimpleTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var activity: StatusIndicatorState
        var unread: UnreadState = .none
        var simple: [StatusIndicatorState]
        var testDescription: String { "\(activity) unread \(unread)" }
    }

    static let cases: [Case] = [
        Case(activity: .idle, simple: []),
        Case(activity: .working, simple: [.working]),
        Case(activity: .working(progress: 0.4), simple: [.working(progress: 0.4)]),
        Case(activity: .busy(progress: nil), simple: [.busy(progress: nil)]),
        Case(activity: .waiting, simple: [.success]),
        Case(activity: .waiting(kind: .question), simple: [.success]),
        Case(activity: .waiting(kind: .permission), simple: [.success]),
        Case(activity: .waiting(kind: .auth), simple: [.success]),
        Case(activity: .error, simple: [.success]),
        Case(activity: .success, simple: [.success]),
        Case(activity: .idle, unread: .count(3), simple: [.success]),
        // Something to look at outranks work still running in the same workspace.
        Case(activity: .working, unread: .dot, simple: [.success]),
    ]

    @Test(arguments: cases)
    func byDefaultARowIsWorkingOrReady(_ c: Case) {
        let badges = WorkspaceRowBadges(unread: c.unread, activity: c.activity, detailed: false)
        #expect(badges.items == c.simple)
    }

    @Test func detailedIconsKeepEachStateMostUrgentFirst() {
        let badges = WorkspaceRowBadges(unread: .count(2), activity: .waiting(kind: .question), detailed: true)
        #expect(badges.items == [.waiting(kind: .question), .success, .success])
        #expect(WorkspaceRowBadges(unread: .none, activity: .error, detailed: true).items == [.error])
        #expect(WorkspaceRowBadges(unread: .none, activity: .working, detailed: true).items == [.working])
    }

    /// Ready under the default icon set is the blue unread dot, not a check or a bubble.
    @Test func readyIsTheBlueDot() {
        let plan = StatusIndicatorPlan.make(.success, style: .arc, animates: true, set: StatusIconSet.tunable.defaultValue)
        #expect(plan.glyph == .mark(.vector(.dot)))
        #expect(plan.tint == .unread)
    }

    private static let asking = WorkspaceID("ws-asking")
    private static let failing = WorkspaceID("ws-failing")
    private static let busy = WorkspaceID("ws-busy")

    /// A sidebar whose rows read `sidebar.detailedStatusIcons` from its settings, in `style`.
    private static func sidebar(detailed: Bool, style: SidebarRowBadgeStyle) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let asking = SidebarWorkspace(id: asking, title: "deploy", kind: .terminal, unread: .count(2), activity: .waiting(kind: .question))
        let failing = SidebarWorkspace(id: failing, title: "tests", kind: .terminal, activity: .error)
        var busy = SidebarWorkspace(id: busy, title: "build", kind: .terminal, activity: .working)
        busy.agentWorking = true // agent work shows only on a row whose agent is working
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(asking), .workspace(failing), .workspace(busy)]),
        ])
        model.rowBadgeStyle = style
        let design = DesignSettings()
        design.sidebarSections.detailedStatusIcons = detailed
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func badge(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> RowBadgeView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView).rowBadge
    }

    @Test(arguments: [SidebarRowBadgeStyle.corner, .stack])
    func rowsDrawOneBareGlyphByDefault(_ style: SidebarRowBadgeStyle) throws {
        #expect(SidebarSectionsPreferences.defaults.detailedStatusIcons == false)
        let sidebar = Self.sidebar(detailed: false, style: style)
        let asking = try Self.badge(sidebar, Self.asking)
        #expect(asking.states == [.success], "a question is Ready: the blue dot")
        #expect(asking.look == .plain && !asking.drawsBackdrop, "no disc behind the dot")
        // The tooltip still says what waits.
        #expect(asking.themedToolTip?.contains(Strings.unreadCount(2)) == true)
        #expect(try Self.badge(sidebar, Self.failing).states == [.success], "an error is Ready")
        #expect(try Self.badge(sidebar, Self.busy).states == [.working], "work is the one spinner")
    }

    @Test func detailedStatusIconsDrawEachState() throws {
        let sidebar = Self.sidebar(detailed: true, style: .stack)
        #expect(try Self.badge(sidebar, Self.asking).states == [.waiting(kind: .question), .success, .success])
        #expect(try Self.badge(sidebar, Self.failing).states == [.error])
        #expect(try Self.badge(sidebar, Self.busy).states == [.working])
    }
}
