import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-10-23: "for chief home page, i see tabbar now which is bad. home chief should have no
/// tabbar" (and 2026-10-20: "should not even show tabs UI for left hand side chief"). #24052 (Leo
/// 2026-10-21) made Home's Chief pane, its pinned chat dock, show its tab bar; it shows none again,
/// and Hide/Show Tab Bar and New Horizontal Tab are not offered for it (plans/cmux-next/home-chief-pane.md H1).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct HomeChiefPaneHasNoTabBarTests {
    @Test func theLoneHomeChiefPaneShowsNoTabBar() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let chief = try #require(window.focusedPane)
            #expect(HomeSplitKeysTests.panes(home).count == 1, "Home's chat dock stands alone")
            #expect(chief.isPinnedDockPane, "the focused pane is Home's pinned chat dock")
            try await PasswordManagerRouteTests.until({ chief.view.hidesStrip },
                                                       report: { "the Home Chief pane shows a tab bar (strip \(chief.view.stripHeight) pt)" })

            let toggle = ActionInvocation(target: ActionTargetRef(kind: .pane, id: chief.pane.id), origin: .user)
            let refusal = services.registry.capturingRefusal { _ = services.registry.perform(PaneTabBarHandlers.toggle, invocation: toggle) }
            #expect(refusal != nil, "Show Tab Bar is offered on the Home Chief pane")
            #expect(chief.view.hidesStrip, "Show Tab Bar brought a tab bar to the Home Chief pane")
        }
    }
}
