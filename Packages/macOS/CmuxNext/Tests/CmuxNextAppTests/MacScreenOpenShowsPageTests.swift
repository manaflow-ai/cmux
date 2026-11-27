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

    /// The walk's own state (judged run 17:49Z, NIGHTLY 4598798383801 @946de8b): a fresh launch on Home, its pinned
    /// dock alone in a 1100x720 window, no top page; Screen Sharing opened again and again (palette, shortcut, File
    /// menu, chevron, CLI, one session). Every open shows the page's home, with its keyboard toggle, in the window.
    @Test func screenSharingFromHomesDockShowsItsHomeEveryTime() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (controller, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let window = try #require(controller.window)
            window.setContentSize(NSSize(width: 1100, height: 720))
            for open in 1...3 {
                services.openMacScreen(in: nil)
                try await PasswordManagerRouteTests.until({
                    window.contentView?.layoutSubtreeIfNeeded()
                    let tabs = HomeSplitKeysTests.panes(home).flatMap(\.tabs).filter { $0.page == InternalPageID.macScreen.rawValue }
                    return tabs.count == open && AccessibilityAudit().identifiers(under: window).contains("macScreen.home")
                }, report: { Self.describe(controller, home: home, window: window, open: open) })
            }
        }
    }

    private static func describe(_ controller: WindowController, home: WorkspaceModel, window: NSWindow, open: Int) -> String {
        let columns = home.screens.map { screen in
            screen.columns.map { "\($0.dock == nil ? "column" : "dock") \($0.layout.paneIDs.map(\.rawValue))" }
        }
        let panes = (controller.content?.panes.values.map { $0 } ?? []).map { pane in
            "\(pane.paneKey): \(pane.pane.tabs.map { $0.page ?? "\($0.kind)" }) selected \(pane.stripModel.selectedID?.rawValue ?? "none")"
        }
        let layout = controller.content?.layoutModel
        return "open \(open): columns \(columns), panes \(panes), focused \(String(describing: controller.focusedPane?.paneKey)), "
            + "visible \(layout.map { $0.visiblePanes.map(\.rawValue).sorted() } ?? []), keepAlive \(layout.map { $0.keepAlivePanes.map(\.rawValue).sorted() } ?? []), "
            + "identifiers \(AccessibilityAudit().identifiers(under: window).sorted().prefix(60))"
    }
}
