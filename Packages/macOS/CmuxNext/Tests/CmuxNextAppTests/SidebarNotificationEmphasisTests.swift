import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Aziz 2026-11-05: a workspace's notification in the sidebar "doesn't capture my attention enough", and row
/// decorations were "too timid". `sidebar.notificationEmphasis` offers three surfaces beside the dot-only default:
/// an inbox shelf pinned at the top, an arrival card with a row flash, and loud rows with edge beacons. These draw
/// a real sidebar in each look and check what a person sees.
@MainActor @Suite(.serialized) struct SidebarNotificationEmphasisTests {
    private static let unread = WorkspaceID("ws-unread"), read = WorkspaceID("ws-read"), asks = WorkspaceID("ws-asks")

    private static func rows(fillers: Int = 0, unreadCount: Int = 3) -> [SidebarWorkspace] {
        var rows = [
            SidebarWorkspace(id: unread, title: "api", kind: .terminal, unread: unreadCount > 0 ? .count(unreadCount) : .none, activity: .idle),
            SidebarWorkspace(id: read, title: "docs", kind: .terminal, unread: .none, activity: .idle),
            SidebarWorkspace(id: asks, title: "deploy", kind: .terminal, unread: .none, activity: .waiting(kind: .permission)),
        ]
        // Rows with nothing for the person, before the ones that have something, so those can be scrolled away.
        rows.insert(contentsOf: (0..<fillers).map { SidebarWorkspace(id: WorkspaceID("ws-filler-\($0)"), title: "filler \($0)", kind: .terminal) }, at: 0)
        return rows
    }

    private static func sections(_ rows: [SidebarWorkspace]) -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: rows.map(SidebarNode.workspace))]
    }

    private static func sidebar(fillers: Int = 0, height: CGFloat = 600) -> SidebarView {
        let sidebar = SidebarView(model: SidebarModel(sections: sections(rows(fillers: fillers))), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.refreshAttention()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
    }

    /// Runs `body` with the look set to `look`, then clears it (the store is active without a file).
    private static func with(_ look: SidebarNotificationEmphasis, _ body: () throws -> Void) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarNotificationEmphasis.tunable.key
        try #require(TunableStore.shared.set(key, look.tunableValue) == look.tunableValue)
        SidebarTunablesWatch.shared.changed()
        defer {
            TunableStore.shared.set(key, nil)
            SidebarTunablesWatch.shared.changed()
        }
        try body()
    }

    @Test func theDefaultKeepsTheDotAloneAndNoSurface() throws {
        #expect(SidebarNotificationEmphasis.tunable.defaultValue == .standard)
        try Self.with(.standard) {
            let sidebar = Self.sidebar()
            let row = try Self.row(sidebar, Self.unread)
            #expect(!row.rowBadge.isHidden && !row.emphasis.isLoud && row.emphasis.pill.isHidden)
            #expect(sidebar.attention.inbox.isHidden && sidebar.attention.arrival.isHidden)
            #expect(sidebar.attention.above.isHidden && sidebar.attention.below.isHidden)
            #expect(sidebar.scrollView.contentInsets.top == 0)
        }
    }

    @Test func theInboxPinsEveryWorkspaceWithANotificationAtTheTopMostUrgentFirst() throws {
        try Self.with(.inbox) {
            let sidebar = Self.sidebar()
            let inbox = sidebar.attention.inbox
            #expect(!inbox.isHidden && inbox.frame.height > 0)
            #expect(inbox.items.map(\.id) == [Self.asks, Self.unread], "needs you before unread; a read workspace is not listed")
            #expect(inbox.frame.minY < sidebar.scrollView.frame.minY + inbox.frame.height, "pinned at the list's top")
            #expect(sidebar.scrollView.contentInsets.top >= inbox.frame.height, "the list scrolls under it, no row hidden")
        }
    }

    @Test func aNewNotificationRaisesTheArrivalCardButOneWaitingAtLaunchDoesNot() throws {
        try Self.with(.arrivalCard) {
            let sidebar = Self.sidebar()
            #expect(sidebar.attention.arrival.isHidden, "what already waited when the sidebar first drew is not an arrival")
            var docs = try #require(sidebar.model.workspace(Self.read))
            docs.unread = .count(2)
            #expect(sidebar.model.patchWorkspaces([docs]))
            sidebar.refreshAttention()
            sidebar.layoutSubtreeIfNeeded()
            let card = sidebar.attention.arrival
            #expect(!card.isHidden && card.items.map(\.id) == [Self.read])
            #expect(card.frame.maxY > sidebar.scrollView.frame.midY, "at the bottom of the list")
            // Read: it leaves the card.
            docs.unread = .none
            #expect(sidebar.model.patchWorkspaces([docs]))
            sidebar.refreshAttention()
            #expect(card.isHidden)
        }
    }

    @Test func arrivalsQueueNewestFirstAndDismissEmptiesIt() throws {
        var arrivals = SidebarArrivals()
        let item = { (id: WorkspaceID) throws -> SidebarAttentionItem in SidebarAttentionItem(id: id, title: id.rawValue, attention: try #require(WorkspaceRowAttention(
            SidebarWorkspace(id: id, title: "x", kind: .terminal, unread: .count(1), activity: .idle)))) }
        let first = arrivals.update([])
        #expect(first.isEmpty, "what waits at the first update is not an arrival")
        let second = arrivals.update([try item(Self.unread)])
        #expect(second == [Self.unread])
        let third = arrivals.update([try item(Self.unread), try item(Self.read)])
        #expect(third == [Self.read])
        #expect(arrivals.queue == [Self.read, Self.unread], "newest first")
        arrivals.dismiss()
        #expect(arrivals.queue.isEmpty)
    }

    @Test func loudRowsPaintSolidWithACountPillInsteadOfTheDot() throws {
        try Self.with(.loudRows) {
            let sidebar = Self.sidebar()
            let unread = try Self.row(sidebar, Self.unread), read = try Self.row(sidebar, Self.read), asks = try Self.row(sidebar, Self.asks)
            #expect(unread.emphasis.isLoud && !unread.emphasis.pill.isHidden && unread.rowBadge.isHidden)
            #expect(asks.emphasis.isLoud, "a workspace that needs you is loud too")
            #expect(!read.emphasis.isLoud && read.emphasis.pill.isHidden)
            unread.updateLayer()
            #expect(unread.title.textColor == .white)
        }
    }

    @Test func loudRowsShowABeaconForRowsScrolledOutOfView() throws {
        try Self.with(.loudRows) {
            let sidebar = Self.sidebar(fillers: 40, height: 300)
            #expect(sidebar.attention.below.count == 2, "both rows with a notification are below the visible part")
            #expect(!sidebar.attention.below.isHidden && sidebar.attention.above.isHidden)
        }
    }
}
