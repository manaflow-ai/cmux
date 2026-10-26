import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A workspace parked under a top page lays out nothing (ParkedWorkspaceApplyTests), so its view's
/// panes are the tree as of parking. A page tab opened there without changing the view (a script's
/// `openSettings`, a background show) must go into a pane the MODEL has, never into a pane the
/// daemon closed meanwhile.
@MainActor @Suite(.serialized) struct ParkedWorkspacePageTabTests {
    @Test func aPageTabOpenedUnderATopPageGoesToAPaneTheModelHas() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let window = try #require(services.windows.active)
            let content = try #require(window.workspaceContent)
            let workspace = content.workspace
            let first = try #require(workspace.screens.first?.panes.first)
            // The window shows a top page: its workspace parks, off screen.
            try #require(window.showTopPage(.page(.stats)), "the stats page did not show as a top page")
            // The daemon splits it and closes the first pane while it is parked.
            _ = try await connection.split(first.handle, direction: .right)
            try await connection.closePane(first.handle)
            // The store holds both commands' events (read-your-writes on the reply), not a poll.
            try #require(await services.daemon.appliedThroughReply(on: connection, after: "split and close"))
            let panes = workspace.screens.flatMap(\.panes)
            try #require(panes.count == 1 && panes.first !== first,
                         "panes \(panes.map { "\($0.id)/\($0.handle)" }) first \(first.id)/\(first.handle)")
            let live = try #require(workspace.screens.flatMap(\.panes).first)

            // A background open: no focus, the top page stays.
            #expect(services.pages.openNew(.inbox, in: window, focus: false) != nil)
            // In the open's own turn: the store tab shows (its intent) in a pane the model has, or the app-only
            // tab is listed under it; never under the pane the daemon closed.
            let inLive = live.tabs.contains { $0.page == InternalPageID.inbox.rawValue }
                || services.pages.tab(of: .inbox, inPanes: [live.id]) != nil
            #expect(inLive, "the page did not open in the pane the model has (\(live.id))")
            #expect(services.pages.tab(of: .inbox, inPanes: [first.id]) == nil, "the page went into the pane the daemon closed")
        }
    }
}
