import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// A tab action that has nothing to act on says why (unimpl-audit-actions.md rows 25-27): the
/// right-clicked tab's menu row is disabled with the reason, and a palette, CLI or MCP run is
/// refused with it, instead of an enabled row that does nothing and a run that reports success.
/// Runs the app's registry against a same-tree cmux-tui daemon, as the tab menu and the CLI reach it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabNothingToDoRefusalTests {
    /// The window's one pane with at least `count` tabs, its strip synced.
    private static func pane(with count: Int, _ services: AppServices, _ connection: DaemonConnection) async throws -> PaneController {
        let pane = try #require(services.windows.active?.workspaceContent?.panes.values.first)
        for _ in pane.pane.tabs.count..<max(count, pane.pane.tabs.count) { _ = try await connection.newTab(in: pane.pane.handle) }
        try await PinnedPageTests.until({ pane.stripModel.tabs.count >= count }, report: { "\(pane.stripModel.tabs.map(\.id))" })
        return pane
    }

    private static func target(_ id: StripTabID) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .tab, id: id.rawValue))
    }

    /// The menu row's reason for the tab (nil: enabled) and a CLI run's refusal.
    private static func outcome(_ id: ActionID, on tab: StripTabID, _ services: AppServices) -> (menu: String?, cli: String?) {
        let menu = ActionTargetReasons.reason(for: id, invocation: target(tab), in: services.registry)
        let cli = services.registry.capturingRefusal {
            _ = services.registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.rawValue), origin: .cli))
        }
        return (menu, cli)
    }

    @Test func closeTabsToTheRightOfTheLastTabSaysThereAreNone() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 2, services, connection)
            let ordered = pane.orderedIDs
            let last = try #require(ordered.last), first = try #require(ordered.first)
            #expect(ActionTargetReasons.reason(for: "closeTabsToRight", invocation: Self.target(first), in: services.registry) == nil,
                    "the first tab has tabs to its right")
            let (menu, cli) = Self.outcome("closeTabsToRight", on: last, services)
            #expect(menu != nil, "the last tab's Close Tabs to the Right row is enabled and does nothing")
            #expect(cli != nil, "a CLI run on the last tab reports success and closes nothing")
            #expect(pane.orderedIDs == ordered, "a tab closed")
        }
    }

    @Test func closeTabsToTheLeftOfTheFirstTabSaysThereAreNone() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 2, services, connection)
            let ordered = pane.orderedIDs
            let first = try #require(ordered.first), last = try #require(ordered.last)
            #expect(ActionTargetReasons.reason(for: "closeTabsToLeft", invocation: Self.target(last), in: services.registry) == nil,
                    "the last tab has tabs to its left")
            let (menu, cli) = Self.outcome("closeTabsToLeft", on: first, services)
            #expect(menu != nil, "the first tab's Close Tabs to the Left row is enabled and does nothing")
            #expect(cli != nil, "a CLI run on the first tab reports success and closes nothing")
            #expect(pane.orderedIDs == ordered, "a tab closed")
        }
    }

    @Test func closeOtherTabsOnALoneTabSaysThereAreNone() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 1, services, connection)
            try #require(pane.orderedIDs.count == 1, "the pane starts with \(pane.orderedIDs.count) tabs")
            let only = try #require(pane.orderedIDs.first)
            let (menu, cli) = Self.outcome("closeOtherTabsInPane", on: only, services)
            #expect(menu != nil, "a lone tab's Close Other Tabs row is enabled and does nothing")
            #expect(cli != nil, "a CLI run on a lone tab reports success and closes nothing")
            // The palette (no target: the focused tab) is refused too.
            let palette = services.registry.capturingRefusal { _ = services.registry.perform("closeOtherTabsInPane", invocation: ActionInvocation()) }
            #expect(palette != nil, "the palette's Close Other Tabs on a lone tab reports nothing")
        }
    }

    @Test func duplicateTabOnAPageTabSaysAPageOpensOnce() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 1, services, connection)
            let terminal = try #require(pane.orderedIDs.first)
            #expect(ActionTargetReasons.reason(for: "duplicateTab", invocation: Self.target(terminal), in: services.registry) == nil,
                    "a terminal tab duplicates")
            let key = services.pages.open(.diff, in: pane.paneKey, of: services.daemon.store)
            try await PinnedPageTests.until({ pane.stripModel.tab(StripTabID(key)) != nil }, report: { "\(pane.orderedIDs)" })
            let before = pane.orderedIDs
            let (menu, cli) = Self.outcome("duplicateTab", on: StripTabID(key), services)
            #expect(menu != nil, "a page tab's Duplicate Tab row is enabled and does nothing")
            #expect(cli != nil, "a CLI run on a page tab reports success and duplicates nothing")
            #expect(pane.orderedIDs == before, "a tab opened")
        }
    }
}
