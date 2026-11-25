import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHistory
import CmuxNextStash
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Stash (a native OneTab, cx-rws36) through the app against a same-tree cmux-tui daemon: the
/// Stashed Tabs page (React, webviews/src/pages/stash) restores and deletes through
/// ``StashService``, which these tests drive directly; Save and Close (StashHandlers) closes a tab
/// or a whole workspace into a stash, and Show Stashed Tabs opens the page. The page's list,
/// search and OneTab paste parsing are covered by webviews/test/stash-page.test.tsx and the
/// daemon's page relay by cmux-tui/tests/page_router.rs.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct StashTests {
    @Test func theServiceRestoresAndDeletesTabsAndGroups() async throws {
        try await AppHarnessWindows.withApp { services, connection in
            let stash = services.historyPage.stash
            let store = services.daemon.store
            let urls = (0..<3).map { "https://stash-\(UUID().uuidString.prefix(6).lowercased()).example/\($0)" }
            _ = try await connection.state.importOneTab([.init(name: nil, pages: urls.map { .init(url: $0, title: "Page") })],
                                                        engine: stash.importEngine)
            let imported = try #require(try await Self.group(urls: urls, connection))

            // A row's ×: that tab goes for good.
            try await stash.delete(imported.id, members: [imported.members[0].id])
            let afterDelete = try #require(try await Self.group(id: imported.id, connection))
            #expect(afterDelete.members.compactMap(\.url) == Array(urls[1...]))

            // A row's click: that tab comes back; the group keeps the rest.
            try await stash.restore(imported.id, members: [afterDelete.members[0].id], inNewWorkspace: false)
            try await PinnedPageTests.until({ Self.tab(url: urls[1], store) != nil }, report: { "no tab at \(urls[1])" })
            #expect(try await Self.group(id: imported.id, connection)?.members.compactMap(\.url) == [urls[2]])
            #expect(Self.tab(url: urls[0], store) == nil, "the deleted tab never came back")

            // Restore in New Workspace: every tab left, in a workspace of its own; the emptied group goes.
            let workspaces = Set(store.workspaces.map(\.id))
            try await stash.restore(imported.id, members: nil, inNewWorkspace: true)
            #expect(try await Self.group(id: imported.id, connection) == nil)
            try await PinnedPageTests.until({
                store.workspaces.contains { !workspaces.contains($0.id) && Self.urls(of: $0).contains(urls[2]) }
            }, report: { "no new workspace with \(urls[2])" })

            // Delete Group.
            let gone = "https://stash-delete-\(UUID().uuidString.prefix(6).lowercased()).example/"
            _ = try await connection.state.importOneTab([.init(name: nil, pages: [.init(url: gone, title: "Gone")])], engine: stash.importEngine)
            let doomed = try #require(try await Self.group(urls: [gone], connection))
            try await stash.delete(doomed.id, members: nil)
            #expect(try await Self.group(id: doomed.id, connection) == nil)
        }
    }

    /// An imported page reopens in the app's browser engine (the page's import adds it).
    @Test func anImportedPageReopensInTheAppsBrowserEngine() async throws {
        try await AppHarnessWindows.withApp { services, connection in
            let stash = services.historyPage.stash
            let url = "https://stash-\(UUID().uuidString.prefix(6).lowercased()).example/b"
            _ = try await connection.state.importOneTab([.init(name: nil, pages: [.init(url: url, title: "B")])], engine: stash.importEngine)
            let group = try #require(try await Self.group(urls: [url], connection))
            try await stash.restore(group.id, members: nil, inNewWorkspace: false)
            let store = services.daemon.store
            try await PinnedPageTests.until({ Self.tab(url: url, store) != nil })
            guard case .open(let choice) = services.cache.browserTabs.resolve(requested: nil) else {
                Issue.record("no browser engine resolves")
                return
            }
            #expect(Self.tab(url: url, store)?.browserEngine == choice.engine.rawValue)
        }
    }

    /// Save and Close Tab on a browser tab: the page goes into a stash and leaves its pane, as the
    /// tab menu, the palette and `cmux tab stash` run it.
    @Test func saveAndCloseTabStashesTheBrowserPage() async throws {
        try await AppHarnessWindows.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(store.workspaces.first?.screens.first?.panes.first?.handle)
            let url = "https://stash-\(UUID().uuidString.prefix(6).lowercased()).example/tab"
            let surface = try await connection.newFrontendBrowserTab(url: url, engine: .webkit, in: pane, activate: false).surface
            try await PinnedPageTests.until({ store.tab(surface: surface)?.resourceID != nil })
            let tab = try #require(store.tab(surface: surface))
            let target = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .cli)
            #expect(ActionTargetReasons.reason(for: "tab.stash", invocation: target, in: services.registry) == nil)

            let failures = try await Self.perform("tab.stash", target, services)
            #expect(failures.isEmpty, "\(failures)")
            try await PinnedPageTests.until({ Self.tab(url: url, store) == nil }, report: { "the page is still open" })
            #expect(try await Self.group(urls: [url], connection) != nil, "the page is in no stash")
        }
    }

    /// A terminal tab is no web page: its menu shows Save and Close Tab disabled with the reason.
    @Test func saveAndCloseTabRefusesATerminal() async throws {
        try await AppHarnessWindows.withApp { services, connection in
            let store = services.daemon.store
            let created = try await connection.state.createWorkspace(name: "stash-pty", ephemeral: false, terminal: true, focus: false)
            @MainActor func terminal() -> TabModel? {
                store.workspaces.first { $0.resourceID == created.workspaceID }?.screens.flatMap(\.panes).flatMap(\.tabs).first { $0.kind == .pty }
            }
            try await PinnedPageTests.until({ terminal() != nil }, report: { "the new workspace has no terminal tab" })
            let terminal = try #require(terminal())
            let target = ActionInvocation(target: ActionTargetRef(kind: .tab, id: terminal.id))
            #expect(ActionTargetReasons.reason(for: "tab.stash", invocation: target, in: services.registry) == StashHandlerStrings.noPage)
        }
    }

    /// Save and Close Other Tabs on one of several selected tabs keeps every selected tab, as Close
    /// Other Tabs does (`closedByCloseOthers(keepingAll:)`): only the pages outside the selection go.
    @Test func saveAndCloseOtherTabsKeepsTheWholeSelection() async throws {
        try await AppHarnessWindows.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(services.windows.active?.workspaceContent?.panes.values.first)
            let tag = UUID().uuidString.prefix(6).lowercased()
            let urls = (0..<4).map { "https://stash-\(tag).example/\($0)" }
            for url in urls {
                _ = try await connection.newFrontendBrowserTab(url: url, engine: .webkit, in: pane.pane.handle, activate: false)
            }
            @MainActor func stripID(_ url: String) -> TabID? {
                pane.stripModel.orderedTabs.first { pane.tab($0.id)?.url == url && pane.tab($0.id)?.resourceID != nil }?.id
            }
            try await PinnedPageTests.until({ urls.allSatisfy { stripID($0) != nil } }, report: { "\(pane.stripModel.orderedTabs.map(\.id))" })
            // A click on the second page, then a Cmd-click on the third, as the strip does.
            let kept = try [urls[1], urls[2]].map { try #require(stripID($0)) }
            for (id, click) in zip(kept, [TabMultiSelection.Click.plain, .toggle]) {
                if let next = pane.stripModel.click(id, click) { pane.select(next) }
            }
            try await PinnedPageTests.until({ Set(pane.stripModel.selectedTabIDs) == Set(kept) },
                                            report: { "selected \(pane.stripModel.selectedTabIDs)" })

            // The tab menu opened on one of the selected tabs.
            let target = ActionInvocation(target: ActionTargetRef(kind: .tab, id: kept[0].rawValue),
                                          arguments: ActionInvocation.tabSelectionArguments, origin: .cli)
            let failures = try await Self.perform("tab.stashOthers", target, services)
            #expect(failures.isEmpty, "\(failures)")
            try await PinnedPageTests.until({ Self.tab(url: urls[0], store) == nil && Self.tab(url: urls[3], store) == nil },
                                            report: { "a page outside the selection is still open" })
            #expect(Self.tab(url: urls[1], store) != nil, "a selected page was saved and closed")
            #expect(Self.tab(url: urls[2], store) != nil, "a selected page was saved and closed")
            let stashed = try await connection.state.stashes().first { $0.members.contains { $0.url == urls[0] } }
                .map { Set($0.members.compactMap(\.url)) }
            #expect(stashed == [urls[0], urls[3]], "the stash holds \(String(describing: stashed))")
        }
    }

    /// Save and Close Workspace: the workspace closes whole, its terminal too, into one stash of
    /// one workspace member, and Restore All brings the workspace back.
    @Test func saveAndCloseWorkspaceStashesItWhole() async throws {
        try await AppHarnessWindows.withApp { services, connection in
            try #require(services.daemon.supports(DaemonCapability.stashWorkspaces.rawValue), "the same-tree daemon stashes whole workspaces")
            let store = services.daemon.store
            let name = "stash-ws-\(UUID().uuidString.prefix(6).lowercased())"
            let created = try await connection.state.createWorkspace(name: name, ephemeral: false, terminal: true, focus: false)
            try await PinnedPageTests.until({ store.workspaces.contains { $0.resourceID == created.workspaceID && $0.key != nil } })
            let workspace = try #require(store.workspaces.first { $0.resourceID == created.workspaceID })
            let target = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: workspace.id), origin: .cli).confirmed()

            let failures = try await Self.perform("workspace.stash", target, services)
            #expect(failures.isEmpty, "\(failures)")
            try await PinnedPageTests.until({ !store.workspaces.contains { $0.name == name } }, report: { "the workspace is still open" })
            let group = try #require(try await Self.group(workspace: name, connection), "no stash holds the workspace")
            #expect(group.members.count == 1)
            #expect(group.members.first?.kind == .workspace)

            try await services.historyPage.stash.restoreAll(group.id, workspaces: true)
            try await PinnedPageTests.until({ store.workspaces.contains { $0.name == name } }, report: { "the workspace did not come back" })
            #expect(try await Self.group(id: group.id, connection) == nil)
        }
    }

    /// Save and Close Workspace with a remote-terminal tab (#24192): the app stops following the
    /// tab (its placeholder, live surface and title follow go, as a close lets them go), and
    /// Restore All brings the tab back on the same terminal, which the stash kept.
    @Test func saveAndCloseWorkspaceLetsGoOfItsRemoteTerminalTabs() async throws {
        try await AppHarnessWindows.withApp { services, connection in
            try #require(services.daemon.supports(DaemonCapability.stashWorkspaces.rawValue), "the same-tree daemon stashes whole workspaces")
            let store = services.daemon.store
            let name = "stash-remote-\(UUID().uuidString.prefix(6).lowercased())"
            let created = try await connection.state.createWorkspace(name: name, ephemeral: false, terminal: true, focus: false)
            // The store lists the workspace before its first pane arrives, so wait for the pane too.
            try await PinnedPageTests.until({
                store.workspaces.contains { $0.resourceID == created.workspaceID && $0.key != nil && $0.screens.first?.panes.first?.handle != nil }
            }, report: { "the workspace has no pane" })
            let workspace = try #require(store.workspaces.first { $0.resourceID == created.workspaceID })
            let pane = try #require(workspace.screens.first?.panes.first?.handle)
            // A terminal on a machine this app has not connected to: the tab shows its placeholder.
            let ref = RemoteTerminalRef(sessionID: UUID().uuidString.lowercased(),
                                        terminalID: TerminalID(rawValue: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()),
                                        sessionName: "stash-remote-machine")
            let surface = try await connection.newRemoteTerminalTab(ref, in: pane).surface
            try await PinnedPageTests.until({ store.tab(surface: surface)?.kind == .remoteTerminal }, report: { "no remote-terminal tab" })
            let tab = try #require(store.tab(surface: surface))
            _ = services.remoteTerminals.content(for: tab, home: services.daemon)
            try #require(services.remoteTerminals.existingPlaceholder(tab.id) != nil, "the remote-terminal tab shows no placeholder")

            let target = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: workspace.id), origin: .cli).confirmed()
            let failures = try await Self.perform("workspace.stash", target, services)
            #expect(failures.isEmpty, "\(failures)")
            try await PinnedPageTests.until({ !store.workspaces.contains { $0.name == name } }, report: { "the workspace is still open" })
            #expect(services.remoteTerminals.existingPlaceholder(tab.id) == nil, "the stashed remote-terminal tab is still followed")

            let group = try #require(try await Self.group(workspace: name, connection), "no stash holds the workspace")
            try await services.historyPage.stash.restoreAll(group.id, workspaces: true)
            try await PinnedPageTests.until({
                store.workspaces.first { $0.name == name }?.screens.flatMap(\.panes).flatMap(\.tabs).contains { $0.remote == ref } == true
            }, report: { "the workspace did not come back with its remote-terminal tab" })
        }
    }

    /// Another machine's workspace row leaves Save and Close Workspace out of its menu (Stash keeps
    /// this Mac's), as a tab row on another machine's pane leaves out Save and Close Tab. It showed
    /// enabled, then refused with "No workspace here can be saved". This Mac's rows keep it.
    @Test func anotherMachinesWorkspaceRowLeavesOutSaveAndClose() async throws {
        try await CrossMachineTabMoveTests.withMachines { world in
            let registry = world.services.registry
            @MainActor func hidden(_ id: ActionID, _ workspace: WorkspaceModel) -> Bool {
                ActionTargetVisibility.isHidden(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: workspace.id)),
                                                in: registry)
            }
            // Rows act on registered workspaces (a key); each daemon's registry names its own.
            @MainActor func registered(_ store: DaemonStore, _ match: (WorkspaceModel) -> Bool) -> WorkspaceModel? {
                store.workspaces.first { $0.key != nil && match($0) }
            }
            try await PinnedPageTests.until({ registered(world.machine.daemon.store) { $0.id == world.target.id } != nil },
                                            report: { "the other machine's workspace has no key" })
            let there = try #require(registered(world.machine.daemon.store) { $0.id == world.target.id })
            #expect(hidden("workspace.stash", there), "another machine's workspace row offers Save and Close Workspace")
            try await PinnedPageTests.until({ registered(world.services.daemon.store) { _ in true } != nil },
                                            report: { "this Mac's workspace has no key" })
            let mac = try #require(registered(world.services.daemon.store) { _ in true })
            #expect(!hidden("workspace.stash", mac), "this Mac's workspace row leaves out Save and Close Workspace")
        }
    }

    /// Undo of a Save and Close restores on every path: the stash goes even when the host that
    /// shows restored pages is gone by the time the daemon answers.
    @Test func restoreAllRestoresWhenNothingShowsTheRestoredPages() async throws {
        try await AppHarnessWindows.withApp { services, connection in
            let url = "https://stash-\(UUID().uuidString.prefix(6).lowercased()).example/undo"
            _ = try await connection.state.importOneTab([.init(name: nil, pages: [.init(url: url, title: "Undo")])], engine: "webkit")
            let service = StashService(host: VanishingStashHost(services))
            let group = try #require(try await Self.group(urls: [url], connection))

            try await service.restoreAll(group.id, workspaces: false)
            try await PinnedPageTests.until({ Self.tab(url: url, services.daemon.store) != nil }, report: { "the page did not come back" })
            #expect(try await Self.group(id: group.id, connection) == nil, "the daemon still lists the restored stash")
        }
    }

    /// Show Stashed Tabs from automation opens the page as a tab without moving the window's view.
    @Test func showStashedTabsOpensThePage() async throws {
        try await AppHarnessWindows.withApp { services, _ in
            try #require(services.pages.keys(of: .stashed).isEmpty, "a Stashed Tabs page was open before the action")
            let failures = try await Self.perform("stash.show", ActionInvocation(origin: .cli), services)
            #expect(failures.isEmpty, "\(failures)")
            let key = try #require(services.pages.keys(of: .stashed).first, "the action opened no Stashed Tabs page")
            #expect(services.pages.view(for: key)?.page == .stashed, "no Stashed Tabs page opened")
            #expect(URL(string: "cmux://stashed/")?.isStashedPage == true)
            #expect(URL(string: "cmux://history")?.isStashedPage == false)
        }
    }

    /// `<scheme>://stashed` opened from another app (ExternalOpenRouter's deep link) or Open Link…
    /// goes through `link.open`, which shows the Stashed Tabs page instead of refusing the link.
    @Test func theStashedLinkOpensThePage() async throws {
        try await AppHarnessWindows.withApp { services, _ in
            try #require(services.pages.keys(of: .stashed).isEmpty, "a Stashed Tabs page was open before the link")
            let link = "\(services.linkScheme)://stashed"
            let failures = try await Self.perform("link.open", ActionInvocation(arguments: ["url": .string(link)], origin: .cli), services)
            #expect(failures.isEmpty, "\(failures)")
            #expect(!services.pages.keys(of: .stashed).isEmpty, "the link opened no Stashed Tabs page")
        }
    }

    /// Runs `id` as the CLI does (capturing its refusal and work) and returns every failure.
    private static func perform(_ id: ActionID, _ invocation: ActionInvocation, _ services: AppServices) async throws -> [String] {
        var ran = false
        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork { ran = services.registry.perform(id, invocation: invocation) }
        }
        var failures = refusal.map { [$0] } ?? []
        if !ran { failures.append("\(id) did not run") }
        for task in work { if let failure = await task.value { failures.append(failure.message) } }
        return failures
    }

    /// The App's Stash host that lets go of itself once a restore asks for its pane, so the
    /// restore's answer finds no host (as when the services go while an Undo runs).
    @MainActor
    private final class VanishingStashHost: StashHost {
        private let app: StashAppHost
        private var keepAlive: VanishingStashHost?

        init(_ services: AppServices) {
            app = StashAppHost(services)
            keepAlive = self
        }

        var localDaemon: DaemonService { app.localDaemon }
        var stashImportEngine: String { app.stashImportEngine }

        var stashRestorePane: ResourceID? {
            defer { keepAlive = nil }
            return app.stashRestorePane
        }

        func showRestored(_ reopened: StateResourceClient.ReopenedItem, asWorkspace: Bool) {
            app.showRestored(reopened, asWorkspace: asWorkspace)
        }
    }

    private static func group(id: String, _ connection: DaemonConnection) async throws -> StashRecord? {
        try await connection.state.stashes().first { $0.id == id }
    }

    private static func group(urls: [String], _ connection: DaemonConnection) async throws -> StashRecord? {
        try await connection.state.stashes().first { $0.members.compactMap(\.url) == urls }
    }

    private static func group(workspace name: String, _ connection: DaemonConnection) async throws -> StashRecord? {
        try await connection.state.stashes().first { $0.members.first?.name == name }
    }

    private static func tab(url: String, _ store: DaemonStore) -> TabModel? {
        store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.url == url }
    }

    private static func urls(of workspace: WorkspaceModel) -> [String] {
        workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap(\.url)
    }
}
