import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-21: "THIS ADDING TABS: IT SWITCHES AROUND AND DOESN'T REALLY GET ADDED". Since chats
/// dock (#23105), Cmd-T in a docked chat's pane sent its tab to the column on the right, so the tab
/// never showed where it was added. Cmd-T in a pane that takes tabs adds exactly one tab to that
/// pane, right after the selected tab, selects it, and moves no other tab, in that pane or any other.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabStaysInItsPaneTests {
    @Test func cmdTInADockedChatsPaneAddsOneTabAfterTheSelectedOne() async throws {
        try await addsOneTabAfterTheSelectedOneInADock(action: "newTab.default")
    }

    /// Option-click on the + (`StripNewTab.sameKindAction`, New <Kind> Tab) on a browser tab in the dock:
    /// a browser tab in the dock, not in the strip column on its right.
    @Test func optionPlusOnABrowserTabInADockAddsOneTabAfterTheSelectedOne() async throws {
        try await addsOneTabAfterTheSelectedOneInADock(action: StripNewTab.sameKindAction)
    }

    /// Two browser tabs in an agent chat dock left of the main strip, the first selected; `action` runs on
    /// the dock pane as the strip's + runs it (`StripNewTab.request`: a `.pane` target, origin `.user`).
    private func addsOneTabAfterTheSelectedOneInADock(action: ActionID) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-new-tab-stays")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let window = try #require(services.windows.active)
            let strip = try #require(window.focusedPane)
            let store = services.daemon.store
            @MainActor func tabID(_ surface: SurfaceID) async throws -> String {
                try await PasswordManagerRouteTests.until { store.tab(surface: surface) != nil }
                return try #require(store.tab(surface: surface)).id
            }
            // Two pages; the first moves into an agent chat dock left of the strip, the second follows it there.
            let first = try await connection.newFrontendBrowserTab(url: "https://example.com/a", engine: .webkit,
                                                                   in: strip.pane.handle, activate: false)
            let firstID = try await tabID(first.surface)
            let firstTab = try #require(store.tab(surface: first.surface))
            let moved = await withCheckedContinuation { done in
                TabMoves.toNewDockColumn(firstTab, anchor: strip.pane, edge: .left,
                                         role: .agentChat, services: services) { done.resume(returning: $0) }
            }
            try #require(moved, "the page did not move into a chat dock")
            @MainActor func dock() -> PaneController? {
                window.workspaceContent?.panes.values.first { $0.pane.tabs.contains { $0.id == firstID } && $0 !== strip }
            }
            try await PasswordManagerRouteTests.until({ dock() != nil }, report: { "no dock pane holds \(firstID)" })
            let dockPane = try #require(dock())
            try #require(ChatDockRules.isChatDock(dockPane.pane, services: services), "the column is not an agent chat dock")
            try #require(dockPane.stripModel.showsNewTabButton, "an unpinned chat dock takes tabs")
            let second = try await connection.newFrontendBrowserTab(url: "https://example.com/b", engine: .webkit,
                                                                    in: dockPane.pane.handle, activate: false)
            let secondID = try await tabID(second.surface)
            try await PasswordManagerRouteTests.until { dockPane.orderedIDs.map(\.rawValue) == [firstID, secondID] }
            dockPane.select(TabID(firstID))
            try #require(dockPane.stripModel.selectedID?.rawValue == firstID)
            let stripBefore = strip.orderedIDs.map(\.rawValue)

            let target = ActionTargetRef(kind: .pane, id: dockPane.paneKey)
            #expect(services.registry.perform(action, invocation: ActionInvocation(target: target, origin: .user)))

            @MainActor func order() -> [String] { dockPane.orderedIDs.map(\.rawValue) }
            try await PasswordManagerRouteTests.until({ order().count == 3 && !order().contains(where: ProvisionalTab.isProvisional) },
                                                      report: { "dock strip: \(order()), main strip: \(strip.orderedIDs.map(\.rawValue))" })
            // Past the new-tab placement window: the order and selection hold.
            try await Task.sleep(for: .seconds(1))
            let after = order()
            #expect(after.count == 3, "dock strip: \(after)")
            #expect(after.first == firstID && after.last == secondID, "the new tab is not right after the selected one: \(after)")
            #expect(dockPane.stripModel.selectedID?.rawValue == after[1], "selected \(dockPane.stripModel.selectedID?.rawValue ?? "none"), strip \(after)")
            #expect(strip.orderedIDs.map(\.rawValue) == stripBefore, "the main strip changed: \(stripBefore) -> \(strip.orderedIDs.map(\.rawValue))")
        }
    }
}
