import AppKit
@testable import CmuxNextAccounts
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Logins done right, first real run (Settings > Accounts in the right pane, GitHub's Add Account): the
/// provider's sign-in page opened as a second, unselected tab in Settings' own pane, hidden behind it,
/// while the card said "Enter this code on the sign-in page beside this window". Leo: "theres no reason
/// for us not only to be able to have shit side by side opened where it's convienient". The page opens
/// beside the pane showing the code (``LinkOpener/openSignInPage(_:beside:)``): a new split on its right,
/// a second sign-in a tab selected in that same pane (never another split), and the keyboard stays on the code.
/// Where nothing beside it takes the page (a page source with a pane on its left opens in its own pane, as
/// Settings rightmost did at 1096 wide), the page is selected there with the keyboard, and the sign-in's end
/// shows the code's tab again unless the person moved to another tab. Runs ``LinkOpener`` against a same-tree daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct SignInPageOpensBesideTests {
    /// Never a real provider: the host does not resolve, so nothing leaves the machine.
    static let page = URL(string: "https://auth.example.test/codex/device")!

    @Test func theSignInPageSplitsBesideTheCodeAndASecondReusesThatPane() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            // Wide enough that halving the pane keeps both halves over the width floors (RightColumnPlacement).
            services.windows.active?.window?.setFrame(NSRect(x: 0, y: 0, width: 1800, height: 900), display: true)
            try await PinnedPageTests.until({ (LinkOpener.width(of: pane) ?? 0) >= 2 * RightColumnPlacement.minimumChatWidth },
                                            report: { "the pane did not widen: \(LinkOpener.width(of: pane) ?? -1)" })
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            services.linkOpener.placement = { .splitRight }
            let panes = Set(content.panes.keys)

            var ends: [@MainActor () -> Void] = []
            let first = try await Self.open(services) { ends.append(services.linkOpener.openSignInPage(Self.page, beside: pane.view)) }
            @MainActor func right() -> PaneController? {
                content.panes.first { !panes.contains($0.key) && $0.value.pane.tabs.contains { $0.id == first } }?.value
            }
            try await PinnedPageTests.until({ right()?.stripModel.selectedID?.rawValue == first },
                                            report: { "the sign-in page is not shown in a split beside the code: " + Self.describe(content) })
            #expect(!pane.pane.tabs.contains { $0.id == first }, "the sign-in page opened in the code's own pane: \(Self.describe(content))")
            try await PinnedPageTests.until({ content.focusedPane === pane },
                                            report: { "the sign-in page took the keyboard from the code: " + Self.describe(content) })
            let side = try #require(right())
            let afterFirst = Set(content.panes.keys)

            let second = try await Self.open(services) { ends.append(services.linkOpener.openSignInPage(Self.page, beside: pane.view)) }
            try await PinnedPageTests.until({ side.stripModel.selectedID?.rawValue == second },
                                            report: { "a second sign-in is not selected in the pane beside the code: " + Self.describe(content) })
            #expect(Set(content.panes.keys) == afterFirst, "a second sign-in made another split: \(Self.describe(content))")
            #expect(content.focusedPane === pane, "a second sign-in took the keyboard from the code: \(Self.describe(content))")

            // Each sign-in's end (Cancel, finished, expired) closes the page it opened and no other: the
            // second's leaves the first's, and the first's then empties the split, which goes away.
            @MainActor func tabs() -> Set<String> { Set(content.panes.values.flatMap { $0.pane.tabs.map(\.id) }) }
            ends[1]()
            try await PinnedPageTests.until({ !tabs().contains(second) }, report: { "the second sign-in's end left its page open: " + Self.describe(content) })
            #expect(tabs().contains(first), "the second sign-in's end closed the first's page: \(Self.describe(content))")
            ends[0]()
            try await PinnedPageTests.until({ !tabs().contains(first) && Set(content.panes.keys) == panes },
                                            report: { "the first sign-in's end left its page or its split: " + Self.describe(content) })
        }
    }

    /// Settings rightmost beside Chief home in a 1096-wide window (the first real run's layout, a browser
    /// tab standing in for the Settings page): the sign-in page opens selected in the code's own pane with the
    /// keyboard, its end selects the code's tab again, and once the person picked another tab it stays.
    @Test func withNoRoomBesideTheCodeThePageShowsInItsPaneAndTheEndShowsTheCodeAgain() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            services.windows.active?.window?.setFrame(NSRect(x: 0, y: 0, width: 1096, height: 720), display: true)
            services.linkOpener.placement = { .splitRight }
            let panes = Set(content.panes.keys)
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            @MainActor func made() -> PaneController? {
                content.panes.first { !panes.contains($0.key) && $0.value.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }?.value
            }
            try await PinnedPageTests.until({ made() != nil }, report: { "the split did not confirm" })
            let codePane = try #require(made())
            let other = try #require(codePane.pane.tabs.first { !ProvisionalTab.isProvisional(surface: $0.surface) })
            // A closed loopback port: the page never loads, and nothing leaves the machine.
            let code = try await connection.newFrontendBrowserTab(url: "http://127.0.0.1:9/accounts", engine: .webkit, in: codePane.pane.handle, activate: true)
            // The daemon's reply does not select the tab here (fleet Mac, 2026-11-25: listed, never selected), so the
            // test picks it, as a person on the code's page has.
            try await PinnedPageTests.until({ codePane.pane.tabs.contains { $0.surface == code.surface } }, report: { "the code's page is not listed: " + Self.describe(content) })
            if let listed = codePane.pane.tabs.first(where: { $0.surface == code.surface }) { codePane.select(TabID(listed.id)) }
            try await PinnedPageTests.until({ codePane.selectedTab?.surface == code.surface }, report: { "the code's page is not shown: " + Self.describe(content) })
            PaneHandlers.focus(codePane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === codePane })
            let codeTab = try #require(codePane.selectedTab?.id)
            let layout = Set(content.panes.keys)

            var back: (@MainActor () -> Void)?
            let first = try await Self.open(services) { back = services.linkOpener.openSignInPage(Self.page, beside: codePane.view) }
            try await PinnedPageTests.until({ codePane.stripModel.selectedID?.rawValue == first && content.focusedPane === codePane },
                                            report: { "the sign-in page is not selected with the keyboard in the code's pane: " + Self.describe(content) })
            #expect(Set(content.panes.keys) == layout, "no room, yet the layout changed: \(Self.describe(content))")
            let end = try #require(back)
            end()
            try await PinnedPageTests.until({ codePane.stripModel.selectedID?.rawValue == codeTab },
                                            report: { "the sign-in's end did not show the code's tab again: " + Self.describe(content) })
            try await PinnedPageTests.until({ !codePane.pane.tabs.contains { $0.id == first } }, report: { "the sign-in's end left its page open: " + Self.describe(content) })

            let second = try await Self.open(services) { back = services.linkOpener.openSignInPage(Self.page, beside: codePane.view) }
            try await PinnedPageTests.until({ codePane.stripModel.selectedID?.rawValue == second }, report: { "a second sign-in page is not selected: " + Self.describe(content) })
            codePane.select(CmuxNextTabs.TabID(other.id))
            try await PinnedPageTests.until({ codePane.stripModel.selectedID?.rawValue == other.id })
            let end2 = try #require(back)
            end2()
            #expect(codePane.stripModel.selectedID?.rawValue == other.id, "the sign-in's end took the person off the tab they picked: \(Self.describe(content))")
        }
    }

    /// From the onboarding tool window (the Agents step) over Home or another top page: the page would open in a
    /// workspace the top page covers, so the top page is left, as a terminal sign-in leaves it, and shows again
    /// once the tool window closes (``OnboardingService``).
    @Test func fromTheToolWindowTheSignInPageLeavesATopPageWhichComesBackOnClose() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            #expect(TopPages.show(.page(.history), services: services) != nil)
            #expect(window.shownTopPage == .page(.history))
            services.onboarding.show(step: .agents)
            let tool = try #require(services.onboarding.controller)
            let open = try #require(services.onboarding.signInHarnesses.openSignInPage)
            let store = services.daemon.store
            let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
            let back = try #require(await open(Self.page, []))
            #expect(window.shownTopPage == nil, "the sign-in page opened under a top page")
            try await PinnedPageTests.until({ store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).contains { !before.contains($0.id) } },
                                            report: { "the sign-in page opened no tab" })
            back()
            tool.close()
            try await PinnedPageTests.until({ window.shownTopPage == .page(.history) },
                                            report: { "closing the tool window did not show the top page again: \(String(describing: window.shownTopPage))" })
        }
    }

    /// The tab `open` made, once the daemon lists it.
    private static func open(_ services: AppServices, _ open: () -> Void) async throws -> String {
        let store = services.daemon.store
        let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
        open()
        @MainActor func opened() -> String? {
            store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { !before.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }?.id
        }
        try await PinnedPageTests.until({ opened() != nil }, report: { "the sign-in page opened no tab" })
        return try #require(opened())
    }

    /// Each pane: focused or not, its selected tab and its tabs.
    private static func describe(_ content: WorkspaceContentController) -> String {
        let focused = content.focusedPane
        return content.panes.values.map { pane in
            "\(pane.layoutPaneID)\(pane === focused ? " (focused)" : ""): \(pane.stripModel.selectedID?.rawValue ?? "none") of \(pane.pane.tabs.map(\.id))"
        }.sorted().joined(separator: "; ")
    }
}
