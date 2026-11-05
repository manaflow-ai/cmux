import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Aziz 2026-11-05: a workspace's notification in the sidebar "doesn't capture my attention
/// enough". `sidebar.notificationEmphasis` offers three louder looks beside the dot-only default:
/// an edge bar with a wash, a bold name with a count pill, and a pulsing halo. These draw real
/// sidebar rows with each look and check what a person sees on a row with a notification and on
/// one without.
@MainActor @Suite(.serialized) struct SidebarNotificationEmphasisTests {
    private static let unread = WorkspaceID("ws-unread"), read = WorkspaceID("ws-read"), asks = WorkspaceID("ws-asks")

    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let rows = [
            SidebarWorkspace(id: unread, title: "api", kind: .terminal, unread: .count(3), activity: .idle),
            SidebarWorkspace(id: read, title: "docs", kind: .terminal, unread: .none, activity: .idle),
            SidebarWorkspace(id: asks, title: "deploy", kind: .terminal, unread: .none, activity: .waiting(kind: .permission)),
        ]
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: rows.map(SidebarNode.workspace))])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
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

    @Test func theDefaultKeepsTheDotAlone() throws {
        #expect(SidebarNotificationEmphasis.tunable.defaultValue == .standard)
        try Self.with(.standard) {
            let row = try Self.row(Self.sidebar(), Self.unread)
            #expect(!row.rowBadge.isHidden, "the dot")
            #expect(row.emphasis.bar.isHidden && row.emphasis.pill.isHidden && row.emphasis.halo.isHidden)
        }
    }

    @Test func theEdgeBarMarksOnlyRowsWithANotification() throws {
        try Self.with(.edgeBar) {
            let sidebar = Self.sidebar()
            let unread = try Self.row(sidebar, Self.unread), asks = try Self.row(sidebar, Self.asks), read = try Self.row(sidebar, Self.read)
            #expect(!unread.emphasis.bar.isHidden && unread.emphasis.bar.frame.height > 0)
            #expect(!asks.emphasis.bar.isHidden, "a row that needs you is a notification too")
            #expect(read.emphasis.bar.isHidden)
            #expect(unread.emphasis.attention?.kind == .unread && asks.emphasis.attention?.kind == .needsYou)
        }
    }

    @Test func theBoldPillShowsTheCountInTheDotsPlaceAndBoldsTheName() throws {
        try Self.with(.boldPill) {
            let sidebar = Self.sidebar()
            let unread = try Self.row(sidebar, Self.unread), read = try Self.row(sidebar, Self.read)
            #expect(!unread.emphasis.pill.isHidden && unread.rowBadge.isHidden, "the pill stands in for the dot")
            #expect(unread.emphasis.attention?.pillText == "3")
            #expect(unread.emphasis.pill.frame.width > 0)
            #expect(NSFontManager.shared.weight(of: unread.title.font ?? .systemFont(ofSize: 1)) > NSFontManager.shared.weight(of: read.title.font ?? .systemFont(ofSize: 1)))
            let asks = try Self.row(sidebar, Self.asks)
            #expect(asks.emphasis.pill.isHidden && !asks.rowBadge.isHidden, "nothing unread: the needs-you mark stays")
        }
    }

    @Test func theHaloSitsBehindTheDotOfARowWithANotification() throws {
        try Self.with(.halo) {
            let sidebar = Self.sidebar()
            let unread = try Self.row(sidebar, Self.unread), read = try Self.row(sidebar, Self.read)
            #expect(!unread.emphasis.halo.isHidden && unread.emphasis.halo.superlayer === unread.rowBadge.layer)
            #expect(unread.emphasis.halo.frame.width > SidebarStyle.statusDotSize)
            #expect(read.emphasis.halo.superlayer == nil || read.emphasis.halo.isHidden)
        }
    }

    @Test func switchingBackToTheDefaultClearsEveryLook() throws {
        let sidebar = Self.sidebar()
        try Self.with(.boldPill) { _ = try Self.row(sidebar, Self.unread) }
        try Self.with(.standard) {
            let row = try Self.row(sidebar, Self.unread)
            #expect(row.emphasis.pill.isHidden && !row.rowBadge.isHidden)
        }
    }
}
