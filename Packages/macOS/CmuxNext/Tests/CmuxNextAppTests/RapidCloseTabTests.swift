import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-12 (cx-ag5.11): Cmd-W hammered closes exactly one tab per
/// press, each the tab selected after the last close, while the daemon has
/// not confirmed any of them yet; the pane keeps a selected tab and the focus.
/// Runs the app's Close Tab against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct RapidCloseTabTests {
    @Test func cmdWHammeredClosesOneTabPerPress() async throws {
        try await PinnedPageTests.withApp { services, connection in try await Self.hammer(services, connection, terminals: false) }
    }

    /// Leo 2026-10-21: the same holds for terminal tabs. Closing a live
    /// terminal first asks the daemon what it runs (the close warning), and
    /// the presses during that read still close one tab each.
    @Test func cmdWHammeredOnTerminalTabsClosesOneTabPerPress() async throws {
        try await PinnedPageTests.withApp { services, connection in try await Self.hammer(services, connection, terminals: true) }
    }

    private static func hammer(_ services: AppServices, _ connection: DaemonConnection, terminals: Bool) async throws {
        let paneModel = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        var surfaces: [SurfaceID] = []
        for index in 0..<4 {
            if terminals {
                surfaces.append(try await connection.newTab(in: paneModel.handle).surface)
            } else {
                let tab = try await connection.newFrontendBrowserTab(url: "https://example.com/\(index)", engine: .webkit, in: paneModel.handle, activate: false)
                surfaces.append(tab.surface)
            }
        }
        let store = services.daemon.store
        try await PinnedPageTests.until({ surfaces.allSatisfy { store.tab(surface: $0) != nil } })
        var ids: [String] = []
        for surface in surfaces { ids.append(try #require(store.tab(surface: surface)).id) }
        let pane = try #require(services.paneController(for: paneModel))
        let wanted = Set(ids)
        try await PinnedPageTests.until({ wanted.isSubset(of: pane.orderedIDs.map(\.rawValue)) })
        let closing = Set(ids.prefix(3))
        let expected: [String] = pane.orderedIDs.map(\.rawValue).filter { !closing.contains($0) }
        pane.select(TabID(ids[0]))
        try #require(pane.stripModel.selectedID?.rawValue == ids[0])
        if terminals {
            // The close warning applies: live terminals in a window, with the setting on.
            let tabs = ids.prefix(3).compactMap { store.tab(id: $0) }
            try #require(TabCloseGuard.asks(tabs, services: services), "the terminal close warning does not apply")
        }

        // Three presses back to back: none waits for the daemon.
        for _ in 0..<3 {
            let performed = services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
            #expect(performed)
        }
        // A terminal's close waits for the daemon's read first; the presses during it close the next tabs.
        if terminals {
            #expect(Set(ids.prefix(3)).isSubset(of: TabCloseGuard.reading), "the closes did not wait for the read")
            try await PinnedPageTests.until({ pane.orderedIDs.map(\.rawValue) == expected })
        }
        let after: [String] = pane.orderedIDs.map(\.rawValue)
        #expect(after == expected, "each press closed the tab selected after the last")
        let selected: String? = pane.stripModel.selectedID?.rawValue
        #expect(selected == ids[3])

        let closed = Array(surfaces.prefix(3))
        try await PinnedPageTests.until({ closed.allSatisfy { store.tab(surface: $0) == nil } })
        #expect(store.tab(surface: surfaces[3]) != nil, "a fourth tab closed")
        let settled: String? = pane.stripModel.selectedID?.rawValue
        #expect(settled == ids[3], "the selection moved off the last tab left")
        let focused = services.windows.active?.workspaceContent?.focusedPane
        #expect(focused === pane, "the pane lost the focus")
    }
}
