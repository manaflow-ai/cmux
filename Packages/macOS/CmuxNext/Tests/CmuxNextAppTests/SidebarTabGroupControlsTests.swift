import AppKit
@testable import CmuxNextDesign
import CmuxNextIcons
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-27, on a workspace's listed tabs (Lawrence's f32ee25f): "it should also just slightly demarcate,
/// you know, which pane you're focused on"; "if you just directly clicked on it, that it, like, showed and hid
/// the thing, because that's what you can do on Chrome"; "when Chrome's chevron is closed, it goes upwards";
/// and the ✕ "this one, not so much ... Here, I'll just highlight what Chrome has" (`SidebarRowCloseSpot`).
@MainActor @Suite(.serialized)
struct SidebarTabGroupControlsTests {
    typealias Gaps = SidebarIncrementalMatchesRebuildGapsTests
    static let shown = WorkspaceID("tg-shown"), other = WorkspaceID("tg-other")
    static let first = TabID("tg-tab-1"), second = TabID("tg-tab-2")

    /// Two workspaces, each with two Claude tabs; the first shown, its second tab focused, the other one working.
    static func sidebar() -> (SidebarModel, SidebarView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        var shown = SidebarWorkspace(id: Self.shown, title: "Sidebar polish")
        shown.tabs = [SidebarTab(id: first, title: "Fold the tab lines", kind: .agentChat),
                      SidebarTab(id: second, title: "Mark the focused tab", kind: .agentChat)]
        shown.focusedTab = second
        var other = SidebarWorkspace(id: Self.other, title: "Release notes", agentWorking: true, activity: .working)
        other.tabs = [SidebarTab(id: TabID("tg-tab-3"), title: "Draft", kind: .agentChat),
                      SidebarTab(id: TabID("tg-tab-4"), title: "Review", kind: .agentChat)]
        other.focusedTab = TabID("tg-tab-3")
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(shown), .workspace(other)])],
                                 activeWorkspaceID: Self.shown)
        model.showWorkspaceTabs = true
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (model, sidebar, window)
    }

    static func withCloseSpot<T>(_ spot: SidebarRowCloseSpot, _ body: () throws -> T) rethrows -> T {
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.activate(file: nil)
        let before = TunableStore.shared.override(SidebarTunables.rowCloseSpot.key)
        TunableStore.shared.set(SidebarTunables.rowCloseSpot.key, .choice(spot.rawValue))
        defer { TunableStore.shared.set(SidebarTunables.rowCloseSpot.key, before) }
        return try body()
    }

    static func tabRow(_ list: SidebarListView, _ workspace: WorkspaceID, _ tab: TabID) throws -> SidebarTabRowView {
        try #require(list.rowViews[.tab(workspace, tab)] as? SidebarTabRowView, "\(tab.rawValue) has no row")
    }

    @Test func theFocusedTabIsMarked() throws {
        let (_, sidebar, window) = Self.sidebar()
        defer { window.close() }
        let focused = try Self.tabRow(sidebar.list, Self.shown, Self.second)
        let plain = try Self.tabRow(sidebar.list, Self.shown, Self.first)
        #expect(focused.isFocusedTab && !plain.isFocusedTab)
        #expect(focused.isAccessibilitySelected() && !plain.isAccessibilitySelected())
        // Every workspace marks its own focused tab.
        #expect(try Self.tabRow(sidebar.list, Self.other, TabID("tg-tab-3")).isFocusedTab)
    }

    /// A tab switch moves the mark: the tab that lost it and the one that took it draw again.
    @Test func aTabSwitchMovesTheMark() throws {
        let (model, sidebar, window) = Self.sidebar()
        defer { window.close() }
        var row = try #require(model.workspace(Self.shown))
        row.focusedTab = Self.first
        #expect(model.patchWorkspaces([row]))
        #expect(try Self.tabRow(sidebar.list, Self.shown, Self.first).isFocusedTab)
        #expect(try !Self.tabRow(sidebar.list, Self.shown, Self.second).isFocusedTab)
    }

    /// Folded, the chevron points up (Chrome's tab group); open, down.
    @Test func theFoldedChevronPointsUp() throws {
        let (model, sidebar, window) = Self.sidebar()
        defer { window.close() }
        let row = try #require(sidebar.list.rowViews[.workspace(Self.shown)] as? WorkspaceRowView)
        #expect(row.disclosureButton.icon == .disclosureExpanded)
        sidebar.list.foldTabs(Self.shown)
        #expect(model.collapsedWorkspaces.contains(Self.shown))
        let folded = try #require(sidebar.list.rowViews[.workspace(Self.shown)] as? WorkspaceRowView)
        #expect(folded.disclosureButton.icon == .disclosureFolded)
    }

    /// A click on the shown workspace's row folds its tabs and the next opens them; a click on another row only
    /// switches to it; a double-click renames and leaves the tabs as they were.
    @Test func aClickOnTheShownRowFoldsItsTabs() throws {
        let (model, sidebar, window) = Self.sidebar()
        defer { window.close() }
        window.orderFrontRegardless()
        let list = sidebar.list
        try Gaps.click(list, .workspace(Self.shown))
        #expect(model.collapsedWorkspaces.contains(Self.shown), "a click on the shown row did not fold its tabs")
        try Gaps.click(list, .workspace(Self.shown))
        #expect(!model.collapsedWorkspaces.contains(Self.shown), "a second click did not open them")
        try Gaps.click(list, .workspace(Self.other))
        #expect(model.activeWorkspaceID == Self.other)
        #expect(!model.collapsedWorkspaces.contains(Self.other), "a click that switched folded the tabs too")
        // A double-click: the first click folds, the second puts the tabs back and renames.
        let point = try Gaps.center(list, .workspace(Self.other))
        list.mouseDown(with: try Gaps.mouse(.leftMouseDown, at: point, in: list))
        list.mouseUp(with: try Gaps.mouse(.leftMouseUp, at: point, in: list))
        #expect(model.collapsedWorkspaces.contains(Self.other))
        let second = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: list.convert(point, to: nil), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        list.mouseDown(with: second)
        #expect(!model.collapsedWorkspaces.contains(Self.other), "a double-click left the tabs folded")
        list.inlineRename.end(commit: false)
    }

    /// The default ✕ spot: on hover, ⋮ ⌄ ✕ with the ✕ on the trailing column, where the status mark gives way;
    /// off hover the mark is back.
    @Test func theCloseEndsTheHoveredRow() throws {
        try Self.withCloseSpot(.end) {
            let (_, sidebar, window) = Self.sidebar()
            defer { window.close() }
            window.orderFrontRegardless()
            sidebar.renderNow()
            let list = sidebar.list
            let row = try #require(list.rowViews[.workspace(Self.other)] as? WorkspaceRowView)
            row.layoutSubtreeIfNeeded()
            let name = Self.other.rawValue
            try #require(!SidebarTrailingColumnTests.marks(in: row, named: name, list: list).isEmpty, "the working row draws no status mark")
            row.isHovered = true
            row.layoutSubtreeIfNeeded()
            let column = SidebarStyle.trailingColumnCenterX(rowWidth: row.bounds.width)
            #expect(abs(row.closeButton.frame.midX - column) < 0.5, "the ✕ at \(row.closeButton.frame.midX), the column at \(column)")
            #expect(row.moreButton.frame.maxX <= row.disclosureButton.frame.minX + 0.5, "⋮ is not left of the chevron")
            #expect(row.disclosureButton.frame.maxX <= row.closeButton.frame.minX + 0.5, "the chevron is not left of the ✕")
            let under = SidebarTrailingColumnTests.marks(in: row, named: name, list: list)
            #expect(under.isEmpty, "a status mark shows under the ✕: \(under.map(\.what))")
            row.isHovered = false
            row.layoutSubtreeIfNeeded()
            #expect(!SidebarTrailingColumnTests.marks(in: row, named: name, list: list).isEmpty, "the status mark stayed hidden after the hover")
        }
    }

    /// The old spot stays a choice: ⋮ ✕ ⌄, the status mark back on the column once the hover ends (Leo 2026-10-28:
    /// "just don't show the spinner" while hovering, under every spot).
    @Test func theMiddleSpotHidesTheMarkOnHover() throws {
        try Self.withCloseSpot(.middle) {
            let (_, sidebar, window) = Self.sidebar()
            defer { window.close() }
            let row = try #require(sidebar.list.rowViews[.workspace(Self.other)] as? WorkspaceRowView)
            window.orderFrontRegardless()
            sidebar.renderNow()
            row.isHovered = true
            row.layoutSubtreeIfNeeded()
            #expect(row.closeButton.frame.maxX <= row.disclosureButton.frame.minX + 0.5)
            let under = SidebarTrailingColumnTests.marks(in: row, named: Self.other.rawValue, list: sidebar.list)
            #expect(under.isEmpty, "a status mark shows beside the hover controls: \(under.map(\.what))")
            row.isHovered = false
            row.layoutSubtreeIfNeeded()
            #expect(!SidebarTrailingColumnTests.marks(in: row, named: Self.other.rawValue, list: sidebar.list).isEmpty)
        }
    }

    /// A change of `sidebar.rowCloseSpot` moves the close on the live rows, with no other change (Codex review).
    @Test func aSpotChangeMovesTheLiveClose() throws {
        try Self.withCloseSpot(.end) {
            let (_, sidebar, window) = Self.sidebar()
            defer { window.close() }
            window.orderFrontRegardless()
            sidebar.renderNow()
            let row = try #require(sidebar.list.rowViews[.workspace(Self.other)] as? WorkspaceRowView)
            row.isHovered = true
            row.layoutSubtreeIfNeeded()
            let column = SidebarStyle.trailingColumnCenterX(rowWidth: row.bounds.width)
            #expect(abs(row.closeButton.frame.midX - column) < 0.5)
            try Self.withCloseSpot(.middle) {
                SidebarTunablesWatch.shared.changed()
                row.layoutSubtreeIfNeeded()
                #expect(row.closeButton.frame.maxX <= row.disclosureButton.frame.minX + 0.5, "the close stayed at the end")
            }
            SidebarTunablesWatch.shared.changed()
        }
    }
}
