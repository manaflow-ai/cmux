import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemonService
import CmuxNextDiff
import CmuxNextLayout
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon

@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct CloudDiffPlacementTests {
    @Test func newAndReusedCloudDiffsReportOnlyConfirmedMovableSurfaces() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"), root: root)
        services.machines.add(machine)
        let store = machine.daemon.store
        let identity = DaemonIdentity(capabilities: ["page-tabs-v1", "page-tab-route-v1"], generation: "cloud-diff-placement")
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        func tree(_ tabs: [TabSnapshot]) -> DaemonTree {
            DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: "cloud-diff", name: "Cloud", screens: [
                ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: tabs)]),
            ])])
        }
        store.apply(snapshot: tree([TabSnapshot(surface: 1, title: "Cloud terminal")]))
        services.windows.registry.provisional["cloud-diff-window"] = ["cloud-diff"]
        let window = services.windows.makeController(for: WindowRegistry.Window(id: "cloud-diff-window"))
        defer { window.teardown(); window.window?.close() }
        services.windows.select("cloud-diff", in: window.state)
        window.showWorkspace(requested: window.state.workspaceID)
        let pane = try #require(window.focusedPane)
        let pages = services.viewers.diffPages
        services.pages.register(pages)
        let link = services.agentGit.link(for: machine.daemon)
        var finish: CheckedContinuation<Void, Never>?
        var creates = 0
        var route: String?
        services.pages.createStoreTab = { _, daemon, _, givenRoute, _ in
            #expect(daemon === machine.daemon)
            creates += 1
            route = givenRoute
            await withCheckedContinuation { finish = $0 }
            return (PageTabCreated(key: "cloud-diff-tab", surface: 80), nil)
        }
        defer { finish?.resume() }
        let repository = DiffRepository(root: "/home/cmux/project", branch: nil, base: nil)
        var reported: [SurfaceID] = []
        let key = pages.open(repository: repository, gitLink: link, in: pane, focus: false, on: machine.daemon,
                             created: { reported.append($0) })
        #expect(pages.route(for: key) == nil, "a VM path must never restore as this Mac's repository")
        guard !services.pages.tabIDs(in: pane.paneKey).contains(key) else {
            Issue.record("Cloud diff has no movable daemon tab")
            return
        }
        try await PasswordManagerRouteTests.until({ finish != nil })
        let reused = pages.open(repository: repository, gitLink: link, in: pane, focus: false, on: machine.daemon,
                                created: { reported.append($0) })
        #expect(reused == key)
        #expect(reported.isEmpty, "reuse reported a provisional surface")
        let reply = finish
        finish = nil
        reply?.resume()
        try await PasswordManagerRouteTests.until({ reported.count == 2 })
        var shown = TabSnapshot(surface: 80, tabResourceID: "cloud-diff-tab", kind: .conversation, title: "Diff")
        shown.conversation = ConversationTabRef(page: "diff")
        store.apply(snapshot: tree([TabSnapshot(surface: 1), shown]))
        let again = pages.open(repository: repository, gitLink: link, in: pane, focus: false, on: machine.daemon,
                               created: { reported.append($0) })
        #expect(again == key)
        #expect(reported == [80, 80, 80])
        #expect(creates == 1)
        #expect(route == nil)
    }

    @Test func unavailableRepositoryDoesNotLeaveABesidePlacementWaiter() async throws {
        let fixture = try await PalettePickerSourcesTests.fixture()
        defer { fixture.close() }
        let services = fixture.services
        let pane = try #require(fixture.controller.focusedPane)
        ViewerHandlers.bind(into: services.registry, context: AppActionContext(services: services))
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.paneKey),
                                          arguments: ["path": .string("/missing-repository")], origin: .cli)
        invocation.besideCaller = true
        invocation.newColumnBeside = true
        let start = ContinuousClock.now
        let work = services.registry.capturingWork { #expect(services.registry.perform("openDiffViewer", invocation: invocation)) }
        var failures: [ActionWorkFailure] = []
        for task in work { if let failure = await task.value { failures.append(failure) } }
        #expect(start.duration(to: .now) < .seconds(5), "repository refusal waited for an impossible tab")
        #expect(!failures.contains { $0.message.contains("new tab did not open") })
    }
    @Test(arguments: [false, true])
    func failedBesideOpenCompletesWithoutAWait(_ newColumn: Bool) async throws {
        let fixture = try await PalettePickerSourcesTests.fixture()
        defer { fixture.close() }
        let services = fixture.services
        let pane = try #require(fixture.controller.focusedPane)
        var invocation = ActionInvocation(origin: .cli)
        invocation.besideCaller = true
        invocation.newColumnBeside = newColumn
        var opening: AgentBesidePlacement.Opening?
        let work = services.registry.capturingWork { opening = AgentBesidePlacement.opening(invocation, in: pane, then: nil) }
        opening?.failed("expected creation failure")
        // A late success after failure cannot select or move a tab.
        opening?.created(1)
        for task in work { #expect(await task.value?.message == "expected creation failure") }
        #expect(pane.pendingSelectSurface == nil)
    }

    @Test func unsupportedBesideDiffRefusesWithoutAnAppOnlyFallback() async throws {
        let fixture = try await PalettePickerSourcesTests.fixture()
        defer { fixture.close() }
        let services = fixture.services
        let pane = try #require(fixture.controller.focusedPane)
        var invocation = ActionInvocation(origin: .cli)
        invocation.besideCaller = true
        invocation.newColumnBeside = true
        let work = services.registry.capturingWork {
            let opening = AgentBesidePlacement.opening(invocation, in: pane, then: nil)
            let key = services.viewers.diffPages.open(repository: DiffRepository(root: "/missing", branch: nil, base: nil),
                in: pane, focus: false, created: opening.created,
                failed: { opening.failed($0.map { ActionWorkFailure("open diff", $0) }) })
            #expect(!services.pages.tabIDs(in: pane.paneKey).contains(key))
        }
        for task in work { #expect(await task.value?.message.contains("page-tabs-v1") == true) }
    }

    @Test func legacyExistingColumnPlacementDoesNotAddAnUnfinishableWaiter() async throws {
        let fixture = try await PalettePickerSourcesTests.fixture()
        defer { fixture.close() }
        let pane = try #require(fixture.controller.focusedPane)
        var invocation = ActionInvocation(origin: .cli)
        invocation.besideCaller = true
        let work = fixture.services.registry.capturingWork {
            _ = AgentBesidePlacement.placed(invocation, in: pane, then: nil)
        }
        #expect(work.isEmpty, "legacy callers cannot finish a failure-aware waiter")
    }

    @Test func nativeChangesReportsAnOfflineMachineWithoutCapturedWork() async throws {
        let fixture = try CloudFileRoutingTests.fixture()
        defer { fixture.close() }
        let services = fixture.services
        var notices: [String] = []
        services.registry.remoteFailureObserver = { _, message in notices.append(message) }
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: fixture.pane.paneKey),
            arguments: ["path": .string("/home/cmux/project")], origin: .user)
        invocation.besideCaller = true
        invocation.besideTakesFocus = true
        invocation.newColumnBeside = true
        #expect(services.registry.perform("openDiffViewer", invocation: invocation))
        try await PasswordManagerRouteTests.until({ !notices.isEmpty })
        #expect(notices.count == 1)
        #expect(notices.first?.contains("Move VM") == true)
        #expect(!notices.contains { $0.contains("new tab did not open") })
    }

    @Test func nativeCreationFailureReportsOnceAndDoesNotLeaveAHiddenDiff() async throws {
        let fixture = try CloudFileRoutingTests.fixture()
        defer { fixture.close() }
        let services = fixture.services
        let daemon = fixture.pane.daemon
        let identity = DaemonIdentity(capabilities: ["page-tabs-v1", "page-tab-route-v1"], generation: "cloud-diff-placement")
        daemon.store.noteHandshake(identity)
        daemon.store.connectionState = .connected(identity)
        services.pages.createStoreTab = { _, _, _, _, _ in throw DaemonError.notConnected }
        var notices: [String] = []
        services.registry.remoteFailureObserver = { _, message in notices.append(message) }
        var invocation = ActionInvocation(origin: .user)
        invocation.besideCaller = true
        invocation.newColumnBeside = true
        let opening = AgentBesidePlacement.opening(invocation, in: fixture.pane, then: nil)
        let key = services.viewers.diffPages.open(repository: DiffRepository(root: "/home/cmux/project", branch: nil, base: nil),
            gitLink: services.agentGit.link(for: daemon), in: fixture.pane, focus: false, on: daemon,
            created: opening.created, failed: { opening.failed($0.map { ActionWorkFailure("open diff", $0) }) })
        try await PasswordManagerRouteTests.until({ !notices.isEmpty })
        #expect(notices.count == 1)
        #expect(!services.pages.tabIDs(in: fixture.pane.paneKey).contains(key))
        #expect(fixture.pane.pane.tabs.count == 1)
    }

    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func simultaneousChangesOpensKeepOneDiffBesideTheDockedChat() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let store = services.daemon.store
            let source = try #require(services.windows.active?.focusedPane)
            let content = try #require(source.workspace)
            let terminals = source.pane.tabs.map(\.surface)
            let chatReply = try await connection.request(NewConversationTabRequest(
                agentSession: AgentSessionRef(host: "install:test", session: "chat", harness: "codex"), pane: source.pane.handle))
            try await PasswordManagerRouteTests.until({ store.tab(surface: chatReply.surface) != nil })
            for terminal in terminals { try await connection.closeTab(terminal) }
            try await PasswordManagerRouteTests.until({ source.pane.tabs.count == 1 })
            let chat = try #require(store.tab(surface: chatReply.surface))
            PaneHandlers.focus(source.layoutPaneID, in: content)
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let machine = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"), root: root)
            services.machines.add(machine)
            let create = services.pages.createStoreTab
            var release: CheckedContinuation<Void, Never>?
            var creates = 0
            services.pages.createStoreTab = { pane, daemon, page, route, transaction in
                creates += 1
                await withCheckedContinuation { release = $0 }
                return try await create(pane, daemon, page, route, transaction)
            }
            defer { services.pages.createStoreTab = create; release?.resume() }
            var invocation = ActionInvocation(origin: .user)
            invocation.besideCaller = true
            invocation.besideTakesFocus = true
            invocation.newColumnBeside = true
            let pages = services.viewers.diffPages
            let work = services.registry.capturingWork {
                for _ in 0..<2 {
                    let opening = AgentBesidePlacement.opening(invocation, in: source, then: nil)
                    pages.open(repository: DiffRepository(root: "/home/cmux/project", branch: nil, base: nil),
                        gitLink: services.agentGit.link(for: machine.daemon), in: source, focus: false, on: machine.daemon,
                        created: opening.created, failed: { opening.failed($0.map { ActionWorkFailure("open diff", $0) }) })
                }
            }
            try await PasswordManagerRouteTests.until({ release != nil })
            let reply = release
            release = nil
            reply?.resume()
            for task in work {
                let failure = await task.value
                #expect(failure == nil, "\(String(describing: failure)); chat \(chat.id) on \(chat.surface), now \(String(describing: store.tab(surface: chat.surface)?.id))")
            }
            #expect(creates == 1)
            let chatPane = try #require(services.locateTab(chat.id, onMachine: services.daemon.machineID).flatMap { services.paneController(for: $0.1) })
            let diffs = store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).filter { $0.page == "diff" }
            #expect(diffs.count == 1)
            let diff = try #require(diffs.first)
            let right = try #require(services.locateTab(model: diff).flatMap { services.paneController(for: $0.1) })
            #expect(right.pane === source.pane)
            #expect(chatPane !== right)
            try await PasswordManagerRouteTests.until({ content.focusedPane === right })
            #expect(services.linkOpener.returnPane(closing: .init(diff.id), in: right, emptiesPane: true) === chatPane)
        }
    }

}
