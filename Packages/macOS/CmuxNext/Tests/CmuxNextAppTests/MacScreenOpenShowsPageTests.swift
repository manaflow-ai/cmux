import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Screen Sharing opened by a person while a top page covers the window: the feature-flows walk (run
/// 45927048373, NIGHTLY 956d6e6) opened it from the shortcut, File menu, chevron and CLI, judged
/// `selected_page == mac-screen`, and read no `macScreen.home` in any window: the tab was selected in a
/// pane the window did not show. #60622 made `macScreen.open` leave the top page; this holds it, from the
/// page and with no `showWorkspace` call, read the way the walk reads it (the window's AX tree).
/// Leo, 2026-11-13: "adding proper paths to screen share thru gui/command palette/wherever reasonable".
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct MacScreenOpenShowsPageTests {
    @Test func screenSharingFromATopPageShowsItsHomeInTheWindow() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            #expect(TopPages.show(.page(.history), services: services) != nil)
            #expect(controller.shownTopPage == .page(.history))

            services.openMacScreen(in: nil)

            let window = try #require(controller.window)
            try await PasswordManagerRouteTests.until({
                window.contentView?.layoutSubtreeIfNeeded()
                return controller.shownTopPage == nil && AccessibilityAudit().identifiers(under: window).contains("macScreen.home")
            }, report: {
                "top page \(String(describing: controller.shownTopPage)), focused \(controller.focus.state.resolved), "
                    + "identifiers \(AccessibilityAudit().identifiers(under: window).sorted().prefix(40))"
            })
        }
    }
}
