import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout
import Foundation
import Testing

/// The Chief panel on the real app and daemon (user 2026-11-06): Show/Hide Chief (Cmd-I) in a workspace that is not
/// Home shows the real Chief (Home's Chief tab's own view) floating over it, never docked and never Home's other
/// panes, and hides it again; in Home, where the Chief already is, it shows nothing over Home.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ChiefDockAppTests {
    @Test func cmdIShowsTheRealChiefFloatingAndHidesIt() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            try #require(!services.home.dock.isClassic, "the docked Home is the default")
            let window = try #require(services.windows.active)
            services.home.ensureHomeWorkspace(connection)
            try await PasswordManagerRouteTests.until({ services.windowHomes.home(in: window.state.id) != nil }, within: .seconds(60),
                                                       report: { services.home.homeWorkspaceStep })
            let home = try #require(services.windowHomes.home(in: window.state.id))
            let other = try #require(await services.windows.createWorkspace(into: window.state.id))
            try await PasswordManagerRouteTests.until({ window.state.workspaceID == other })
            #expect(!window.frameChiefPanelShown, "a new workspace showed the Chief")

            #expect(services.registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ window.frameChiefPanelShown }, report: {
                "open \(window.state.chiefPanel.isOpen), shown \(window.state.workspaceID ?? "-"), home \(window.frameHome ?? "-")"
            })
            #expect(window.chiefPanelView?.chief is HomeHostView, "the panel does not hold the real Chief view")
            #expect(window.state.chiefPanel.dockedEdge == nil && window.state.docks.isEmpty, "Cmd-I docked")
            #expect(window.state.workspaceID == other && window.parked[home.id]?.contentView.isHiddenOrHasHiddenAncestor != false,
                    "Home came on screen with the Chief")

            #expect(services.registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user)))
            #expect(!window.frameChiefPanelShown, "Cmd-I did not hide the Chief")

            // In Home: no panel over it.
            services.windows.show(workspaceID: home.id, in: window.state, from: .thisWindow)
            try await PasswordManagerRouteTests.until({ window.state.workspaceID == home.id })
            _ = services.registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user))
            #expect(!window.frameChiefPanelShown, "the Chief showed over Home")
        }
    }
}
