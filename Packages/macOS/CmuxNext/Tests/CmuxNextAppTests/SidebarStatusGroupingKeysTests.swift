import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Group by Status from the keyboard: Up and Down walk the rows in the grouped order, and a header that folds is a
/// stop between its neighbours (a disclosure, as the Done and Show more rows are). Space and Return fold or unfold
/// it, Left folds, Right unfolds; a header takes focus and its ring, never the selection. Needs you never folds, so
/// its header is no stop.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarStatusGroupingKeysTests {
    typealias Grouping = SidebarStatusGroupingTests

    @Test func arrowsWalkTheGroupedOrderThroughEachFoldingHeader() throws {
        try withSidebar(active: "ask") { sidebar in
            let list = sidebar.view.list
            #expect(SidebarGroupKeys(list: list).stops == [
                .workspace(WorkspaceID("ask")), .workspace(WorkspaceID("asks")),
                .fold(.status(.done)), .workspace(WorkspaceID("shipped")),
                .fold(.status(.failed)), .workspace(WorkspaceID("broke")), .workspace(WorkspaceID("gone")),
                .fold(.status(.ciFailing)), .workspace(WorkspaceID("red")),
                .fold(.status(.working)), .workspace(WorkspaceID("build")),
                .fold(.status(.idle)), .workspace(WorkspaceID("shell")),
            ], "\(SidebarGroupKeys(list: list).stops)")

            try press(125, in: list)
            #expect(list.model.activeWorkspaceID == WorkspaceID("asks"))
            try press(125, in: list)
            #expect(list.focusedFold == .status(.done))
            #expect(list.model.activeWorkspaceID == WorkspaceID("asks"), "a header never takes the selection")
            let header = try #require(list.rowViews[.status(.done)])
            #expect((header.layer?.borderWidth ?? 0) > 0, "the keyboard draws the header's ring")
            try press(125, in: list)
            #expect(list.focusedFold == nil)
            #expect(list.model.activeWorkspaceID == WorkspaceID("shipped"))
            #expect((header.layer?.borderWidth ?? 0) == 0, "leaving the header takes its ring away")
            try press(126, in: list)
            #expect(list.focusedFold == .status(.done))
        }
    }

    @Test func spaceReturnLeftAndRightFoldAFocusedHeader() throws {
        try withSidebar(active: "shipped") { sidebar in
            let list = sidebar.view.list
            try press(126, in: list)
            #expect(list.focusedFold == .status(.done))
            try press(49, in: list) // Space
            #expect(sidebar.model.grouping.collapsed == [.done])
            #expect(!sidebar.drawn.contains("shipped"), "\(sidebar.drawn)")
            #expect(list.displayed.row(for: .status(.done))?.isCollapsed == true)
            #expect(list.focusedFold == .status(.done), "the header keeps focus through its fold")
            try press(36, in: list) // Return
            #expect(sidebar.model.grouping.collapsed.isEmpty)
            #expect(sidebar.drawn.contains("shipped"))
            #expect(!list.inlineRename.isActive, "Return on a header folds, it renames nothing")
            try press(123, in: list) // Left
            #expect(sidebar.model.grouping.collapsed == [.done])
            try press(123, in: list)
            #expect(sidebar.model.grouping.collapsed == [.done], "Left must not open a folded header")
            try press(124, in: list) // Right
            #expect(sidebar.model.grouping.collapsed.isEmpty)
            try press(124, in: list)
            #expect(sidebar.model.grouping.collapsed.isEmpty, "Right must not fold an open header")
        }
    }

    @Test func aFoldedSectionIsOneStopAndTabReachesTheHeaders() throws {
        try withSidebar(active: "asks") { sidebar in
            let list = sidebar.view.list
            sidebar.model.toggleStatusSection(.done)
            sidebar.redraw()
            try press(125, in: list)
            #expect(list.focusedFold == .status(.done))
            try press(125, in: list)
            #expect(list.focusedFold == .status(.failed), "a folded section's rows are no stops")
            try press(48, in: list) // Tab
            #expect(list.focusedFold == .status(.ciFailing))
        }
    }

    private func withSidebar(active: String, _ body: (Grouping.Sidebar) throws -> Void) throws {
        _ = NSApplication.shared
        defer { Grouping.toggle(nil) }
        Grouping.toggle(true)
        let sidebar = Grouping.Sidebar(Grouping.rows, active: WorkspaceID(active))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.contentView = sidebar.view
        sidebar.redraw()
        try body(sidebar)
    }

    private func press(_ code: UInt16, in list: SidebarListView) throws {
        let characters = switch code {
        case 36: "\r"
        case 48: "\t"
        case 49: " "
        case 123: "\u{F702}"
        case 124: "\u{F703}"
        case 125: "\u{F701}"
        case 126: "\u{F700}"
        default: ""
        }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: characters,
                                                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        list.keyDown(with: event)
    }
}
