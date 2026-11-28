import AppKit
import CmuxNextActions
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
    /// Screen Sharing from classic Home, where Home stands for the hidden home workspace (the default
    /// layout): the walk on NIGHTLY 946de8ba (11-27) judged `selected_page == mac-screen` for the
    /// shortcut, File menu, chevron, palette and CLI, and read Home's chat, no `macScreen.home`: the tab
    /// opened in the hidden home workspace. It opens in a workspace the window shows instead.
    @Test func screenSharingFromClassicHomeShowsItsHomeInTheWindow() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let controller = try #require(services.windows.active)
            services.home.ensureHomeWorkspace(connection)
            try await PasswordManagerRouteTests.until({ services.home.homeWorkspace != nil }, within: .seconds(60),
                                                       report: { services.home.homeWorkspaceStep })
            let home = try #require(services.home.homeWorkspace)
            #expect(services.registry.perform("home.show", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ controller.state.workspaceID == home.id }, report: {
                "workspace \(String(describing: controller.state.workspaceID)), page \(String(describing: controller.state.page))"
            })
            try #require(services.home.dock.isClassic && services.sidebarLayout.document.hidesHome && !controller.holdsVisiblePageTab,
                         "Home does not stand for the hidden home workspace here")

            services.openMacScreen(in: nil)

            let window = try #require(controller.window)
            try await PasswordManagerRouteTests.until({
                window.contentView?.layoutSubtreeIfNeeded()
                return controller.holdsVisiblePageTab && AccessibilityAudit().identifiers(under: window).contains("macScreen.home")
            }, within: .seconds(60), report: {
                "workspace \(String(describing: controller.state.workspaceID)) (home \(home.id)), page \(String(describing: controller.state.page)), "
                    + "identifiers \(AccessibilityAudit().identifiers(under: window).sorted().prefix(40))"
            })
            #expect(controller.state.workspaceID != home.id)
        }
    }
}
