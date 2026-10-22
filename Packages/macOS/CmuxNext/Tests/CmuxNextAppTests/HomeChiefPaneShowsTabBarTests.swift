import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Leo 2026-10-21: "JUST MAKE THE TAB THING SHOW UP ON THE MAIN PANE TOO". The main agent pane, Home's
/// Chief pane (its pinned chat dock, alone on the screen), hid its tab bar on its own; every other
/// agent chat pane already showed it (cx-v4dmy). It now shows its tab bar by default, and the person's
/// Hide Tab Bar still hides it (and Show Tab Bar brings it back).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HomeChiefPaneShowsTabBarTests {
    @Test func theLoneHomeChiefPaneShowsItsTabBarUntilThePersonHidesIt() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let chief = try #require(window.focusedPane)
            #expect(HomeSplitKeysTests.panes(home).count == 1, "Home's chat dock stands alone")
            #expect(chief.isPinnedDockPane, "the focused pane is Home's pinned chat dock")
            try await PasswordManagerRouteTests.until({ !chief.view.hidesStrip && chief.view.stripHeight > 0 },
                                                       report: { "the Home Chief pane hides its tab bar by default" })

            let toggle = ActionInvocation(target: ActionTargetRef(kind: .pane, id: chief.pane.id), origin: .user)
            #expect(services.registry.perform(PaneTabBarHandlers.toggle, invocation: toggle), "Hide Tab Bar was not offered")
            try await PasswordManagerRouteTests.until({ chief.view.hidesStrip }, report: { "the person's Hide Tab Bar did not hide it" })
            #expect(services.registry.perform(PaneTabBarHandlers.toggle, invocation: toggle), "Show Tab Bar was not offered")
            try await PasswordManagerRouteTests.until({ !chief.view.hidesStrip }, report: { "Show Tab Bar did not bring it back" })
        }
    }
}
