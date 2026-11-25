import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// A person's New Space opens a chat, not a terminal (David Beyer, 2026-11-20 call: a Space that opens a terminal
/// instead of a chat is a bug). Its first workspace starts on the New Tab page, as a person's New Workspace (Cmd-N)
/// and New Window already do; New Space in the window the person acts in made a bare terminal.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewSpaceOpensAChatTests {
    @Test func aPersonsNewSpaceOpensTheNewTabPage() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "new-space-chat")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let window = try #require(services.windows.active)
            let local = services.machines.local
            try await PasswordManagerRouteTests.until({ local.store.personal.isLoaded && local.supports(DaemonCapability.profiles.rawValue) },
                                                      report: { "personal state not loaded or no profiles-v1" })
            let first = window.state.profileID
            let before = Set(services.daemon.store.workspaces.map(\.id))

            #expect(services.registry.perform("space.new", invocation: ActionInvocation(origin: .user)))
            @MainActor func made() -> [WorkspaceModel] {
                services.daemon.store.workspaces.filter { !before.contains($0.id) }
            }
            @MainActor func tabs() -> [TabModel] { made().flatMap { $0.screens.flatMap(\.panes).flatMap(\.tabs) } }
            @MainActor func isPage(_ tab: TabModel) -> Bool {
                tab.kind == .conversation && tab.agentSession != nil && services.agentTabs.isNewTabPage(tab.id)
            }
            try await PasswordManagerRouteTests.until({ window.state.profileID != first && tabs().contains { isPage($0) || $0.kind == .pty } },
                                                      within: .seconds(30),
                                                      report: { "space \(window.state.profileID.rawValue), tabs: \(tabs().map { "\($0.id) \($0.kind)" })" })
            #expect(made().count == 1, "New Space made \(made().count) workspaces")
            #expect(tabs().count == 1)
            #expect(tabs().allSatisfy(isPage), "the new space opened \(tabs().map { "\($0.kind)" }), not the New Tab page")
        }
    }
}
