import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// A top page (History, Settings, the App Store) covers the window's workspace, but the focus model
/// keeps naming the pane underneath (QA spree 2026-10-23, F24). The notification rules read that
/// model as the tab the person is looking at and typing into: with the App Store open over a
/// terminal, the terminal counted as viewed (its agent's notification posted no banner and no
/// sound under the default `unlessFocused`), and a key typed into the page's search field read the
/// hidden terminal and cleared its unread mark. Under a top page no workspace tab is viewed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TopPageCoversWorkspaceFocusTests {
    @Test func aWorkspaceTabUnderATopPageIsNotTheFocusedTab() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            let notifications = services.notifications
            try await PasswordManagerRouteTests.until({ notifications.focusedTab(in: controller.window) != nil },
                                                      report: { "focus \(controller.focus.state.resolved)" })
            let tab = notifications.focusedTab(in: controller.window)
            // The launch's first workspace may show a terminal or the New Tab page; either is its focused content.
            let terminal = notifications.isTerminalFocused(in: controller.window)

            #expect(TopPages.show(.page(.history), services: services) != nil)
            #expect(controller.shownTopPage == .page(.history))
            #expect(notifications.focusedTab(in: controller.window) == nil,
                    "the terminal under the page is still the focused tab (\(controller.focus.state.resolved))")
            #expect(!notifications.isTerminalFocused(in: controller.window))

            #expect(controller.leaveTopPage())
            try await PasswordManagerRouteTests.until({ notifications.focusedTab(in: controller.window) == tab },
                                                      report: { "focus \(controller.focus.state.resolved)" })
            #expect(notifications.isTerminalFocused(in: controller.window) == terminal)
        }
    }
}
