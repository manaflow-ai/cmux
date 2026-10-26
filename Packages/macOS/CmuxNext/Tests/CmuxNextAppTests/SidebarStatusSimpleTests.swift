import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-18: "everything should either just be 'it is working' or 'it is blue and ready
/// for me to look at it'", with finer icons as an opt-in (`sidebar.detailedStatusIcons`). By default
/// a workspace row's badge is Working (the one spinner), Ready (the blue dot) or, Leo 2026-10-21
/// ("why ISN'T THIS JUST A YELLOW DOT!?"), needs you: one yellow dot in the blue dot's place, never
/// both. A question, a permission request and an auth wait are all needs you, so no chat bubble or
/// shield draws; a finished run is Ready. Lawrence msg 11983: an error is red, not Ready.
@MainActor @Suite(.serialized) struct SidebarStatusSimpleTests {
    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        var activity: StatusIndicatorState
        var unread: UnreadState = .none
        var simple: [StatusIndicatorState]
        var testDescription: String { "\(activity) unread \(unread)" }
    }

    nonisolated static let cases: [Case] = [
        Case(activity: .idle, simple: []),
        Case(activity: .working, simple: [.working]),
        Case(activity: .working(progress: 0.4), simple: [.working(progress: 0.4)]),
        Case(activity: .busy(progress: nil), simple: [.busy(progress: nil)]),
        Case(activity: .waiting, simple: [.waiting]),
        Case(activity: .waiting(kind: .question), simple: [.waiting]),
        Case(activity: .waiting(kind: .permission), simple: [.waiting]),
        Case(activity: .waiting(kind: .auth), simple: [.waiting]),
        // Needs you replaces the blue unread dot: one yellow dot, never both.
        Case(activity: .waiting(kind: .question), unread: .count(2), simple: [.waiting]),
        // Lawrence msg 11983: an error is red, never the blue Ready dot.
        Case(activity: .error, simple: [.error]),
        Case(activity: .error, unread: .dot, simple: [.error]),
        Case(activity: .waiting, unread: .dot, simple: [.waiting]),
        Case(activity: .success, simple: [.success]),
        Case(activity: .idle, unread: .count(3), simple: [.success]),
        // Something to look at outranks work still running in the same workspace.
        Case(activity: .working, unread: .dot, simple: [.success]),
    ]

    @Test(arguments: cases)
    func byDefaultARowIsWorkingReadyOrNeedsYou(_ c: Case) {
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

    /// Needs you under the default icon set is one still dot in the theme's attention (warning) color.
    @Test func needsYouIsTheYellowDot() {
        let plan = StatusIndicatorPlan.make(.waiting, style: .arc, animates: true, set: StatusIconSet.tunable.defaultValue)
        #expect(plan.glyph == .mark(.vector(.dot)))
        #expect(plan.tint == .attention)
        #expect(plan.animation == nil)
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
        #expect(asking.states == [.waiting], "a question is needs you: the yellow dot, not the blue one beside it")
        #expect(asking.look == .plain && !asking.drawsBackdrop, "no disc behind the dot")
        // The tooltip still says what waits.
        #expect(asking.themedToolTip?.contains(Strings.unreadCount(2)) == true)
        #expect(try Self.badge(sidebar, Self.failing).states == [.error], "an error is red (Lawrence msg 11983)")
        #expect(try Self.badge(sidebar, Self.busy).states == [.working], "work is the one spinner")
    }

    @Test func detailedStatusIconsDrawEachState() throws {
        let sidebar = Self.sidebar(detailed: true, style: .stack)
        #expect(try Self.badge(sidebar, Self.asking).states == [.waiting(kind: .question), .success, .success])
        #expect(try Self.badge(sidebar, Self.failing).states == [.error])
        #expect(try Self.badge(sidebar, Self.busy).states == [.working])
    }
}
