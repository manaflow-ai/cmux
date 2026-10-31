import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemonService
import CmuxNextDiff
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
        let identity = DaemonIdentity(capabilities: ["page-tabs-v1", "page-tab-route-v1"])
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
}
