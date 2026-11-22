import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Testing

/// Logins done right, first real run (Settings > Accounts in the right pane, GitHub's Add Account): the
/// provider's sign-in page opened as a second, unselected tab in Settings' own pane, hidden behind it,
/// while the card said "Enter this code on the sign-in page beside this window". Leo: "theres no reason
/// for us not only to be able to have shit side by side opened where it's convienient". The page opens
/// beside the pane showing the code, through ``LinkOpener/openWeb(_:from:background:reusesTab:revealing:)`` from that pane (PageFactory's `openSignInPage`): a new split on its right,
/// a second sign-in a tab selected in that same pane (never another split), and the keyboard stays on the code.
/// Runs ``LinkOpener`` against a same-tree daemon.
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

            let first = try await Self.open(services, beside: pane)
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

            let second = try await Self.open(services, beside: pane)
            try await PinnedPageTests.until({ side.stripModel.selectedID?.rawValue == second },
                                            report: { "a second sign-in is not selected in the pane beside the code: " + Self.describe(content) })
            #expect(Set(content.panes.keys) == afterFirst, "a second sign-in made another split: \(Self.describe(content))")
            #expect(content.focusedPane === pane, "a second sign-in took the keyboard from the code: \(Self.describe(content))")
        }
    }

    /// The page the code's pane asked for, once the daemon lists its tab.
    private static func open(_ services: AppServices, beside pane: PaneController) async throws -> String {
        let store = services.daemon.store
        let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
        _ = services.linkOpener.openWeb(page, from: services.linkOpener.source(containing: pane.view), background: true, revealing: true)
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
