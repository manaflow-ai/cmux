import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-27, on the hover ✕: "this one, not so much ... Here, I'll just highlight what Chrome has"
/// (`SidebarRowCloseSpot`). Also the two-workspace sidebar other tests draw (`sidebar()`, `withCloseSpot`).
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowCloseSpotTests {
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

    /// The default ✕ spot: on hover, ⋮ ✕ with the ✕ on the trailing column, where the status mark gives way;
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
            #expect(row.moreButton.frame.maxX <= row.closeButton.frame.minX + 0.5, "⋮ is not left of the ✕")
            let under = SidebarTrailingColumnTests.marks(in: row, named: name, list: list)
            #expect(under.isEmpty, "a status mark shows under the ✕: \(under.map(\.what))")
            row.isHovered = false
            row.layoutSubtreeIfNeeded()
            #expect(!SidebarTrailingColumnTests.marks(in: row, named: name, list: list).isEmpty, "the status mark stayed hidden after the hover")
        }
    }

    /// The old spot stays a choice: ⋮ ✕ left of the column, the status mark back on the column once the hover ends (Leo 2026-10-28:
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
            #expect(row.closeButton.frame.maxX <= SidebarStyle.trailingColumnStart(rowWidth: row.bounds.width) + 0.5)
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
                #expect(row.closeButton.frame.maxX <= SidebarStyle.trailingColumnStart(rowWidth: row.bounds.width) + 0.5,
                        "the close stayed at the end")
            }
            SidebarTunablesWatch.shared.changed()
        }
    }
}
