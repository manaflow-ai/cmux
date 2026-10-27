import AppKit
@testable import CmuxNextSidebar
import Testing

/// p04-input-042 (`intentPrewarmPress`): the list's mouse-down reports, through `onPressRow`, the workspace row
/// a press commits only on its release (a row with `sidebar.multiView`, a row of a multi-selection), so the App
/// prewarms that row's page while the button is down; a press that switches on the press, and a press on any
/// other row, reports nil. The report changes nothing the person sees: no selection, no shown workspace, no
/// intent before the release. The list is `SidebarPointerGestureTests`': loose `x`, `y`; group `g1` (`a`,
/// `b`); collapsed group `g2` (`c`, `d`); `x` shown.
@MainActor @Suite(.serialized) struct SidebarPressPrewarmTests {
    typealias G = SidebarPointerGestureTests

    /// The list, every press report and every intent it sends (applied, as the App's optimistic update does).
    static func list() -> (SidebarListView, NSWindow, presses: () -> [SidebarRowKey?], intents: () -> [SidebarIntent]) {
        let (list, window) = G.list()
        var presses: [SidebarRowKey?] = []
        var intents: [SidebarIntent] = []
        let model = list.model
        list.onPressRow = { presses.append($0) }
        model.onIntent = { intent in
            intents.append(intent)
            model.apply(intent)
        }
        return (list, window, { presses }, { intents })
    }

    /// What the person sees of the selection: the shown workspace, the selection and the filled rows.
    static func shown(_ list: SidebarListView) -> String {
        SidebarMultiViewPressTests.shown(list)
    }

    @Test func aMultiViewPressReportsItsRowAndChangesNothingBeforeTheRelease() throws {
        try SidebarMultiViewPressTests.withMultiView {
            let (list, window, presses, intents) = Self.list()
            defer { window.close() }
            SidebarMultiViewPressTests.frame(list)
            let before = Self.shown(list)
            let point = try G.point(list, .workspace(WorkspaceID("y")))
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: point))
            SidebarMultiViewPressTests.frame(list)
            #expect(presses() == [.workspace(WorkspaceID("y"))])
            #expect(Self.shown(list) == before, "the press changed the selection: \(Self.shown(list))")
            #expect(intents().isEmpty, "the press sent \(intents())")
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: point))
            #expect(list.model.activeWorkspaceID == WorkspaceID("y"), "the release commits as before")
            #expect(presses().count == 1, "the release reports no press")
        }
    }

    @Test func aPressOnARowOfAMultiSelectionReportsThatRow() throws {
        try SidebarMultiViewPressTests.withMultiView(false) {
            let (list, window, presses, intents) = Self.list()
            defer { window.close() }
            list.model.toggleSelection(WorkspaceID("y"))
            try #require(list.model.selection == [WorkspaceID("x"), WorkspaceID("y")])
            SidebarMultiViewPressTests.frame(list)
            let before = Self.shown(list)
            let point = try G.point(list, .workspace(WorkspaceID("y")))
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: point))
            SidebarMultiViewPressTests.frame(list)
            #expect(presses() == [.workspace(WorkspaceID("y"))])
            #expect(Self.shown(list) == before, "the press changed the selection: \(Self.shown(list))")
            #expect(intents().isEmpty, "the press sent \(intents())")
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: point))
            #expect(list.model.selection == [WorkspaceID("y")], "the release collapses the selection as before")
        }
    }

    /// The default sidebar switches on the press: the switch's show is the commit, nothing is left to prewarm.
    @Test func aPressThatSwitchesOnThePressReportsNil() throws {
        try SidebarMultiViewPressTests.withMultiView(false) {
            let (list, window, presses, _) = Self.list()
            defer { window.close() }
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: try G.point(list, .workspace(WorkspaceID("y")))))
            #expect(presses() == [nil])
            #expect(list.model.activeWorkspaceID == WorkspaceID("y"))
        }
    }

    @Test func aPressOnAGroupHeaderReportsNil() throws {
        try SidebarMultiViewPressTests.withMultiView {
            let (list, window, presses, intents) = Self.list()
            defer { window.close() }
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: try G.point(list, .group(GroupID("g1")))))
            #expect(presses() == [nil])
            #expect(intents().isEmpty)
        }
    }
}
