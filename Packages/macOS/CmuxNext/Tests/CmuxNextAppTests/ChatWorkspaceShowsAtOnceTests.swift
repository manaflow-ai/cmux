import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAgentPane
import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// A chat opened in a new workspace shows in the open's own turn (P4 instant create), as Cmd-N's New
/// Tab page does: its workspace and its chat tab are in the store before any daemon reply, so the
/// chat's page starts loading at once. They waited for the daemon's creates and the store's mirror
/// first: on a perf mini under load the time from the action to the pane was 67-1992 ms per open
/// (job 0163bd2f, STATUS 3752), on the click path of Open Chat and of `agent.openSessionWorkspace`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ChatWorkspaceShowsAtOnceTests {
    /// The workspace `key`'s tabs in the store now.
    private static func tabs(_ key: WorkspaceKey, in store: DaemonStore) -> [TabModel] {
        store.workspaces.first { $0.key == key }.map { $0.screens.flatMap(\.panes).flatMap(\.tabs) } ?? []
    }

    private static func agentTabs(_ services: AppServices) -> AgentTabStore {
        let tabs = services.agentTabs
        tabs.localHost = tabs.localHost ?? AgentSessionRef.host(installID: "chat-at-once-test")
        tabs.holdsTabs = { _ in true }
        return tabs
    }

    @Test func openSessionWorkspaceShowsTheChatBeforeTheDaemonAnswers() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let key = WorkspaceKey.generate()
        let session = "s-at-once-\(UUID().uuidString.prefix(8).lowercased())"

        let work = try AgentSessionWorkspace.open(session: session, name: "lane", key: key, cwd: nil, focus: true, services: services)
        // Same turn as the action: nothing has awaited the daemon yet.
        let atOnce = Self.tabs(key, in: store)
        let failure = await work.value?.message
        let mirrored = await RapidWorkspaceCreateTests.wait(within: .seconds(10)) {
            Self.tabs(key, in: store).contains { !ProvisionalTab.isProvisional(surface: $0.surface) }
        }
        let settled = Self.tabs(key, in: store)
        await launched.stop()

        #expect(atOnce.count == 1, "the action's turn showed \(atOnce.count) tabs of the new workspace (none: it waited for the daemon)")
        #expect(atOnce.first?.kind == .conversation)
        #expect(atOnce.first?.agentSession?.session == session, "the stand-in names the session, so its page opens that chat")
        #expect(failure == nil, "refused: \(failure ?? "")")
        #expect(mirrored, "the daemon's tab never took the stand-in over")
        #expect(settled.count == 1, "the daemon's tab replaced the stand-in in place: \(settled.map(\.surface))")
        #expect(settled.first?.agentSession?.session == session)
    }

    /// The stand-in can be closed before the daemon answers (an agent opened a chat; the person closes its row at
    /// once). The open's task sends create-workspace before any close of the stand-in can be sent, on the same
    /// connection, so the close lands after it: it closes what the daemon made, or makes the open's tab fail on a
    /// closed workspace (the stand-in then goes). Either way no workspace or tab is left, in the store or the daemon,
    /// and the row does not come back. A guard: the base keeps this order (red 3 at d9193990 passed without a lane).
    @Test func aCloseOfTheStandInBeforeTheDaemonAnswersLeavesNothing() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let key = WorkspaceKey.generate()
        let session = "s-close-\(UUID().uuidString.prefix(8).lowercased())"

        let work = try AgentSessionWorkspace.open(session: session, name: "closed lane", key: key, cwd: nil, services: services)
        let standIn = store.workspaces.contains { $0.key == key }
        // Same turn: the daemon has not answered the create yet.
        let ran = services.registry.perform("closeWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: key.rawValue)))
        _ = await work.value
        let gone = await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !store.workspaces.contains { $0.key == key } }
        // Long enough for a create the close missed to list again, then the store caught up with the daemon.
        try await Task.sleep(for: .seconds(2))
        if let connection = services.daemon.connection, let barrier = await connection.eventSequence() {
            await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.appliedSequence >= barrier }
        }
        let back = store.workspaces.filter { $0.key == key }
        let tabLeft = tabs.tab(showing: session, host: tabs.localHost)
        await launched.stop()

        try #require(standIn, "the open showed no stand-in to close")
        #expect(ran, "Close Workspace refused the stand-in")
        #expect(gone, "the workspace never left after its close")
        #expect(back.isEmpty, "the closed workspace is listed again (the daemon's create outlived the close): \(back.map(\.id))")
        #expect(tabLeft == nil, "a chat tab on the session is left: \(tabLeft ?? "")")
    }

    /// A chat opened from a seed (Open Chat on a past chat, New Agent Chat with a prompt) starts its session as soon
    /// as its page loads, which can be before the daemon answered the workspace's create. The page reports that
    /// session under the stand-in's key (`onSessionChange`), where no bind can go; once the daemon's tab takes the
    /// stand-in over, the session is bound to it, so the tab reopens that chat after a relaunch and other windows see
    /// it. Before, the session stayed on the stand-in's key only and the daemon's record kept none.
    @Test func aSessionTheChatStartsBeforeTheDaemonAnswersIsBoundToItsTab() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let window = try #require(services.windows.active?.state.id)
        let before = Set(store.workspaces.map(\.id))
        var spawn = WorkspaceSpawn(name: "started chat")
        spawn.firstChat = AgentPaneSeed(cwd: "/tmp", prompt: "hello")
        let started = "s-started-\(UUID().uuidString.prefix(8).lowercased())"

        let work = services.windows.startWorkspace(spawn, into: window)
        let standIn = store.workspaces.first { !before.contains($0.id) }?.screens.flatMap(\.panes).flatMap(\.tabs).first?.id
        // What the page's model reports when its chat starts (AgentTabStore.wire, onSessionChange), under the stand-in's key.
        if let standIn {
            tabs.sessions[standIn] = started
            tabs.sendSession(started, for: standIn)
        }
        let workspace = try? await work()
        let bound = await RapidWorkspaceCreateTests.wait(within: .seconds(10)) {
            store.workspaces.first { $0.id == workspace }?.screens.flatMap(\.panes).flatMap(\.tabs).first?.agentSession?.session == started
        }
        let record = store.workspaces.first { $0.id == workspace }?.screens.flatMap(\.panes).flatMap(\.tabs).first?.agentSession
        await launched.stop()

        try #require(standIn != nil, "the open showed no stand-in tab")
        #expect(workspace != nil, "the daemon's create failed")
        #expect(bound, "the daemon's tab record holds session \(record?.session ?? "none"), not the one its page started (\(started))")
    }

    /// A stand-in the daemon does not list yet has no slot of its own: it drew where unplaced rows go (first under
    /// `top`, else last), and its slot was applied only once the daemon took it over, so under `afterCurrent`, under
    /// `placement: top` with another setting, or with the window's current workspace in a group, the row drew in one
    /// place and then moved (Leo 2026-11-01: rows must not pop up somewhere and then go where they belong; reviews of
    /// #30961). The open now gives its stand-in the pending row Cmd-N's stand-in has (`PendingWorkspaceRows`), in the
    /// window that will list it, at the slot the setting gives: the row draws there from its first frame.
    @Test(arguments: [("afterCurrent", false), ("bottom", true), ("top", false)])
    func aSessionWorkspaceStandInHasItsRowAtItsSlotFromTheOpensTurn(placement: String, top: Bool) async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let url = launched.root.appendingPathComponent("cmux.json")
        try Data(#"{"workspaces":{"newPlacement":"\#(placement)"}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        try #require(services.settings?.snapshot.newWorkspacePlacement.rawValue == placement)
        let window = try #require(services.windows.registry.value.mostRecentOpen(), "no open window")
        let store = services.daemon.store
        let key = WorkspaceKey.generate()

        let work = try AgentSessionWorkspace.open(session: "s-slot-\(placement)", name: "lane", key: key, cwd: nil, top: top, services: services)
        let shownAtOnce = store.workspaces.contains { $0.key == key }
        let row = PendingWorkspaceRows.shared.rows.first { $0.id == key.rawValue }
        let failure = await work.value?.message
        await launched.stop()

        #expect(shownAtOnce, "the stand-in did not show in the open's turn")
        #expect(row?.window == window, "the stand-in's row has no pending row at its slot in the window that lists it: \(String(describing: row))")
        #expect(row?.byDefault?.placement.rawValue == (top ? "top" : placement), "the row's slot is not the setting's: \(String(describing: row?.byDefault))")
        #expect(failure == nil, "refused: \(failure ?? "")")
    }

    /// An unpinned workspace lists only in Default or in a space that follows its session. A stand-in and its pending
    /// row in a window on another space drew where the workspace never lists, and the row stayed (review of #30961 at
    /// e986d565). Such an open shows nothing before the daemon lists it, as before the instant open.
    @Test func aSessionWorkspaceShowsNothingAtOnceInAWindowWhoseSpaceDoesNotListIt() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let window = try #require(services.windows.registry.value.mostRecentOpen().flatMap { services.windows.states[$0] }, "no open window")
        let space = ProfileID.generate()
        let made = try? await services.machines.local.connection?.createProfile(name: "Work", id: space, color: "blue", icon: nil, browserProfileID: nil)
        await services.machines.local.store.mirrored(profile: space)
        services.windows.switchProfile(space, in: window)
        let store = services.daemon.store
        let key = WorkspaceKey.generate()

        let work = try AgentSessionWorkspace.open(session: "s-space", name: "lane", key: key, cwd: nil, services: services)
        let shownAtOnce = store.workspaces.contains { $0.key == key }
        let row = PendingWorkspaceRows.shared.rows.first { $0.id == key.rawValue }
        let failure = await work.value?.message
        let leftRow = PendingWorkspaceRows.shared.rows.first { $0.id == key.rawValue }
        await launched.stop()

        try #require(made != nil, "the daemon made no space")
        try #require(window.profileID == space, "the window did not enter the space")
        #expect(!shownAtOnce, "the stand-in showed in a window whose space never lists it")
        #expect(row == nil && leftRow == nil, "a pending row was drawn in a space that never lists the workspace: \(String(describing: row ?? leftRow))")
        #expect(failure == nil, "refused: \(failure ?? "")")
    }

    /// The open shows its stand-in and pending row in a window whose space lists the workspace, and the person
    /// switches the window to another space before the daemon lists it. The workspace is unpinned, so that space never
    /// lists it: the row stayed there (the forget rule dropped only a row pinned to another space) and Close/Move of
    /// the window's workspaces were refused while a create looked open (review of #30961 at f9e2549d). The row goes
    /// once the window's space does not list the workspace.
    @Test func aSessionWorkspacesRowGoesWhenItsWindowSwitchesToASpaceThatDoesNotListIt() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let window = try #require(services.windows.registry.value.mostRecentOpen().flatMap { services.windows.states[$0] }, "no open window")
        let space = ProfileID.generate()
        let made = try? await services.machines.local.connection?.createProfile(name: "Work", id: space, color: "blue", icon: nil, browserProfileID: nil)
        try #require(made != nil, "the daemon made no space")
        await services.machines.local.store.mirrored(profile: space)
        let key = WorkspaceKey.generate()

        let work = try AgentSessionWorkspace.open(session: "s-switch", name: "lane", key: key, cwd: nil, services: services)
        let rowAtOnce = PendingWorkspaceRows.shared.rows.contains { $0.id == key.rawValue }
        services.windows.switchProfile(space, in: window) // before the daemon lists the workspace
        let failure = await work.value?.message
        let gone = await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !PendingWorkspaceRows.shared.rows.contains { $0.id == key.rawValue } }
        let left = PendingWorkspaceRows.shared.rows(in: window.id)
        await launched.stop()

        try #require(rowAtOnce, "the open showed no pending row in the Default space")
        #expect(window.profileID == space)
        #expect(gone, "the pending row stayed in a space that never lists the workspace: \(left.map(\.id))")
        #expect(failure == nil, "refused: \(failure ?? "")")
    }

    @Test func openChatShowsItsWorkspaceBeforeTheDaemonAnswers() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let window = try #require(services.windows.active?.state.id)
        let before = Set(store.workspaces.map(\.id))
        var spawn = WorkspaceSpawn(name: "past chat")
        spawn.firstChat = AgentPaneSeed(cwd: "/tmp", pastChat: "claude-code:at-once")

        // Open Chat's path (ChatsOpenCoordinator.createWorkspace): the create starts in this turn.
        let work = services.windows.startWorkspace(spawn, into: window)
        let atOnce = store.workspaces.filter { !before.contains($0.id) }.flatMap { $0.screens.flatMap(\.panes).flatMap(\.tabs) }
        let created = try? await work()
        await launched.stop()

        #expect(atOnce.count == 1, "the open's turn showed \(atOnce.count) chat tabs (none: it waited for the daemon)")
        #expect(atOnce.first?.kind == .conversation)
        #expect(created != nil, "the daemon's create failed")
    }
}
