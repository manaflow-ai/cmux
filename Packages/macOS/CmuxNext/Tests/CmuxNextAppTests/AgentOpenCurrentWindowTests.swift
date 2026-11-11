import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// #41499 F1, on the real daemon: `agent.openSessionWorkspace` (`cmux agent open`) files its workspace into the window
/// the person works in, never the registry's most recent window. Leo 2026-11-11: "Did you open it in a new window?"
/// The window the person works in (W1, `active`) is not the most recent one (W2, ordered front without becoming key, as
/// a window an agent's move opened): before, reconcile gave the new workspace to W2 (`mostRecentOpen`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentOpenCurrentWindowTests {
    private static func agentTabs(_ services: AppServices) -> AgentTabStore {
        let tabs = services.agentTabs
        tabs.localHost = tabs.localHost ?? AgentSessionRef.host(installID: "open-current-window-test")
        tabs.holdsTabs = { _ in true }
        return tabs
    }

    /// Opens a second window, keeps W1 the one the person works in and makes W2 the registry's most recent.
    private static func twoWindows(_ services: AppServices) async throws -> (here: WindowController, other: WindowController) {
        let windows = services.windows
        let here = try #require(windows.active)
        let otherID = windows.newWindow()
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { windows.registry.value.window(otherID)?.isOpen == true }
        let other = try #require(windows.controller(for: otherID), "the second window never opened")
        windows.didActivate(here)
        _ = windows.registry.apply { $0.activate(otherID); return WindowRegistry.Changes() }
        try #require(windows.registry.value.mostRecentOpen() == otherID && windows.active === here, "the two windows are not set up")
        return (here, other)
    }

    @Test(arguments: [nil, "Leads"] as [String?])
    func anAgentsOpenLandsInTheWindowThePersonWorksIn(group: String?) async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        try #require(Self.agentTabs(services).canHostChat, "this build has no agent page")
        let (here, other) = try await Self.twoWindows(services)
        let otherBefore = services.windows.registry.members(of: other.state.id)
        let key = WorkspaceKey.generate()
        let session = "s-current-\(UUID().uuidString.prefix(8).lowercased())"

        let work = try AgentSessionWorkspace.open(session: session, name: "Greeting", key: key, cwd: nil, group: group, services: services)
        let failure = await work.value?.message
        let store = services.daemon.store
        func id() -> String? { store.workspaces.first { $0.key == key && !$0.isProvisional }?.id }
        let listed = await RapidWorkspaceCreateTests.wait(within: .seconds(20)) { id().flatMap { services.windows.registry.value.owner(of: $0) } != nil }
        let owner = id().flatMap { services.windows.registry.value.owner(of: $0) }
        let windowCount = services.windows.registry.value.openWindows.count
        let otherAfter = services.windows.registry.members(of: other.state.id)
        await launched.stop()

        #expect(failure == nil, "refused: \(failure ?? "")")
        #expect(listed, "the opened workspace never joined a window")
        #expect(owner == here.state.id, "the open went to \(owner ?? "no window"), not the window the person works in (\(here.state.id))")
        #expect(otherAfter == otherBefore, "the most recent window took a workspace: \(otherAfter)")
        #expect(windowCount == 2, "the open made a window: \(windowCount) open")
    }
}
