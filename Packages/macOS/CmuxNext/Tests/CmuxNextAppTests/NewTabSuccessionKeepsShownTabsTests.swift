import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Census #7 (CmdTSpamKeepsNewTabsTests, after a window resize): after a Cmd-T burst the strip
/// selected an older new tab, not the newest. While an open waits for its own tab, the pane's
/// other new daemon tabs wait with it (`NewTabSuccession.order`), and that also hid one the
/// strip already showed and selected; the selection took it for closed and moved to a neighbor.
/// Here the open hears its tab's surface before the pane reports that tab (a reply ahead of
/// the report, as under load), with a new tab already shown and selected.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabSuccessionKeepsShownTabsTests {
    @Test func aShownNewTabStaysSelectedWhileTheNextOpenWaitsForItsTab() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let window = try #require(services.windows.active)
            let pane = try #require(window.focusedPane)
            let store = services.daemon.store
            // Anchored on the first of two tabs, the new tab's slot is not where the daemon puts
            // it, so the open stays (as it does for a move's round trip) instead of ending at once.
            if pane.pane.tabs.count < 2 {
                let other = try await connection.newTab(in: pane.pane.handle).surface
                try await PasswordManagerRouteTests.until { store.tab(surface: other) != nil && pane.orderedIDs.count >= 2 }
            }
            let anchor = try #require(pane.orderedIDs.first)
            let open = NewTabSuccession.begin(after: anchor.rawValue, in: pane.pane, services: services)
            // A new tab the strip shows and selects while the open is placed.
            let surface = try await connection.newTab(in: pane.pane.handle).surface
            pane.selectWhenReported(surface: surface)
            try await PasswordManagerRouteTests.until { store.tab(surface: surface) != nil }
            let id = try #require(store.tab(surface: surface)).id
            try await PasswordManagerRouteTests.until({ pane.stripModel.selectedID?.rawValue == id },
                                                      report: { "selected \(pane.stripModel.selectedID?.rawValue ?? "none"), want \(id)" })

            // The open's own tab: answered, not reported yet.
            NewTabSuccession.made(SurfaceID(rawValue: .max), in: pane.pane, by: open)
            try #require(NewTabSuccession.isOpen(in: pane.pane), "the open ended before the check; nothing was proven")
            pane.syncStripFromStore()
            #expect(pane.orderedIDs.contains { $0.rawValue == id }, "the shown new tab left the strip")
            #expect(pane.stripModel.selectedID?.rawValue == id, "selected \(pane.stripModel.selectedID?.rawValue ?? "none"), want \(id)")
        }
    }
}
