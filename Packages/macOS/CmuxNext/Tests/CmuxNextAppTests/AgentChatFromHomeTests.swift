import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// cx-bun: New Agent Chat and Add Harness… over a top page (the window's workspace is parked and
/// shows no pane) open a new workspace with the chat. Before, both waited for a pane the parked
/// workspace never shows and were refused ("No pane is focused").
///
/// Since the docked Home (cx-ebm.59.5) Home is no longer a top page: it is the store's home
/// workspace, hq-ec's page in a left chat dock and a normal workspace on its right. So the chat
/// opens there as in any workspace, and History covers the top-page path.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentChatFromHomeTests {
    /// A script without focus gets the workspace but leaves the window on the page.
    @Test(arguments: [
        ("palette.newAgentChat", ActionOrigin.user, true),
        ("palette.newAgentChat", ActionOrigin.cli, true),
        ("palette.newAgentChat", ActionOrigin.cli, false),
        ("palette.addHarness", ActionOrigin.user, true),
    ])
    func overATopPageTheActionOpensANewWorkspace(_ action: String, _ origin: ActionOrigin, _ focus: Bool) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            let page = TopPageRoute.page(.history)
            #expect(TopPages.show(page, services: services) != nil)
            #expect(window.state.page == page)
            #expect(window.focusedPane == nil, "a top page shows no pane")
            let before = Set(services.daemon.store.workspaces.map(\.id))
            let invocation = ActionInvocation(origin: origin, focusRequested: origin != .user && focus)
            #expect(services.registry.perform(ActionID(rawValue: action), invocation: invocation))
            try await PasswordManagerRouteTests.until {
                services.daemon.store.workspaces.contains { !before.contains($0.id) }
            }
            let created = try #require(services.daemon.store.workspaces.first { !before.contains($0.id) })
            if origin == .user || focus {
                try await PasswordManagerRouteTests.until { window.state.workspaceID == created.id && window.state.page == nil }
            } else {
                #expect(window.state.page == page, "a script without focus switched the window")
            }
        }
    }

    /// The docked Home (the default) is the home workspace with panes: New Agent Chat opens its
    /// chat there, as from any workspace, instead of a refusal or a workspace of its own.
    @Test func fromTheDockedHomeTheChatOpensInTheHomeWorkspace() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            try #require(!services.home.dock.isClassic, "the docked Home is the default")
            let window = try #require(services.windows.active)
            // What the home service runs on each connect (the app starts it at launch, this harness does not).
            services.home.ensureHomeWorkspace(connection)
            try await PasswordManagerRouteTests.until({ services.home.homeWorkspace != nil }, within: .seconds(60),
                                                       report: { services.home.homeWorkspaceStep })
            let home = try #require(services.home.homeWorkspace)
            #expect(services.registry.perform("home.show", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ window.state.workspaceID == home.id && window.focusedPane != nil }, report: {
                "workspace \(String(describing: window.state.workspaceID)), page \(String(describing: window.state.page))"
            })
            #expect(window.state.page == nil, "the docked Home is a workspace, not a top page")
            let workspaces = Set(services.daemon.store.workspaces.map(\.id))
            @MainActor func tabCount() -> Int { home.screens.flatMap(\.panes).flatMap(\.tabs).count }
            let tabs = tabCount()
            #expect(services.registry.perform("palette.newAgentChat", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ tabCount() > tabs }, report: { "\(tabCount()) tabs, was \(tabs)" })
            #expect(Set(services.daemon.store.workspaces.map(\.id)) == workspaces, "no workspace of its own")
            #expect(window.state.workspaceID == home.id && window.state.page == nil, "the window stays on Home")
        }
    }

    /// A top-page transition publishes its page before parking the old content. The action must
    /// follow the page route during that interval instead of opening in the stale focused pane.
    @Test func duringTopPageTransitionTheChatOpensANewWorkspace() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            let oldContent = try #require(window.content)
            let oldWorkspace = oldContent.workspace
            let before = Set(services.daemon.store.workspaces.map(\.id))

            window.state.page = .page(.history)
            #expect(window.focusedPane != nil, "the transition keeps the old pane mounted briefly")
            #expect(services.registry.perform(
                "palette.newAgentChat",
                invocation: ActionInvocation(origin: .cli)
            ))

            try await PasswordManagerRouteTests.until {
                services.daemon.store.workspaces.contains { !before.contains($0.id) }
            }
            let created = try #require(services.daemon.store.workspaces.first { !before.contains($0.id) })
            #expect(created.id != oldWorkspace.id, "a top-page invocation must not use the stale pane")
            // A CLI invocation does not request focus, so the top page may remain shown while
            // the new workspace is created. Placement is established by the new workspace itself.
        }
    }
}
