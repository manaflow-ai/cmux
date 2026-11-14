import AppKit
import CmuxNextActions
@testable import CmuxNextDaemon
import CmuxNextDaemonService
@testable import CmuxNextApp
import CmuxNextWakeups
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import Foundation
import Testing

@MainActor @Suite(.serialized, .closesItsWindows)
struct MacScreenActionRoutingTests {
    private let device = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"

    private func pages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "screen-action-\(UUID().uuidString)/store.json")
        return MacScreenPages(store: MacScreenStore(file: file, removeLinkPairings: {}), work: BackgroundWork())
    }

    @Test func thePinnedCatalogCarriesBothNativeActions() throws {
        let registry = ActionRegistry.standard()
        let open = try #require(registry.descriptor(for: "macScreen.open"))
        #expect(open.arguments.contains { $0.name == "device" })
        let stop = try #require(registry.descriptor(for: "macScreen.stopViewing"))
        #expect(stop.isPaletteVisible)
    }

    @Test(arguments: ActionOrigin.allCases)
    func onlyAPersonsActionRequestsViewOnOpen(origin: ActionOrigin) throws {
        let pages = pages()
        let invocation = ActionInvocation(arguments: ["device": .string(device.uppercased())], origin: origin)
        let result = ActionRunScope.$current.withValueInTask(ActionRunScope(origin: origin, allowsViewChange: true)) {
            Result { try MacScreenActions.record(invocation, pages: pages) }
        }
        let record = try result.get()
        #expect(record.deviceID == device)
        #expect(pages.pendingScopes[device] == (origin == .user ? .view : nil))
    }

    @Test func socketOriginCannotSkipConnectConfirmation() throws {
        let pages = pages()
        var invocation = ActionInvocation(arguments: ["device": .string(device)], origin: .user)
        invocation.viaControlSocket = true
        _ = try MacScreenActions.record(invocation, pages: pages)
        #expect(pages.pendingScopes.isEmpty)
    }

    @Test func aMalformedDeviceDoesNotBecomeTheHomePage() {
        let pages = pages()
        for value: ActionValue in [.string(""), .string("ssh:studio"), .int(1)] {
            #expect(throws: ActionFailure.self) {
                try MacScreenActions.record(ActionInvocation(arguments: ["device": value]), pages: pages)
            }
        }
        #expect(pages.pendingScopes.isEmpty)
    }

    private func screenTree() -> DaemonTree {
        var tab = TabSnapshot(surface: 1, kind: .conversation, title: "Screen")
        tab.conversation = ConversationTabRef(page: InternalPageID.macScreen.rawValue, route: "device:" + device)
        let pane = PaneSnapshot(id: 1, tabs: [tab])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: "screen-route", name: "Screen", screens: [screen])])
    }

    @Test func aDuplicateTabOnAnotherMachineCannotStopTheOwnedViewer() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let otherStore = DaemonStore()
        services.daemon.store.apply(snapshot: screenTree())
        otherStore.apply(snapshot: screenTree())
        let ownedTab = try #require(otherStore.tab(surface: 1))
        #expect(services.daemon.store.tab(surface: 1)?.id == ownedTab.id)
        AgentHandlers.bind(into: services.registry, context: AppActionContext(services: services))
        _ = try #require(services.pages.view(forStoreTab: ownedTab, in: otherStore, local: true, window: nil))
        let key = try #require(services.pages.storeKey(of: ownedTab.id))
        defer { services.pages.close(key) }
        let viewer = try #require(services.macScreenPages.tab(key)?.pane.model.hub)
        viewer.phase = .streaming(sessionID: "owned-elsewhere", scope: .view)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: ownedTab.id), origin: .cli).onMachine("local")
        #expect(!services.registry.perform("macScreen.stopViewing", invocation: invocation))
        #expect(viewer.phase == .streaming(sessionID: "owned-elsewhere", scope: .view))
    }

    @Test func openFromAnAppOnlyTabUsesThatTabsPane() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: screenTree())
        _ = services.windows.registry.apply { $0.openWindow(id: "screen-route-window", workspaceIDs: ["screen-route"]) }
        let window = services.windows.makeController(for: try #require(services.windows.registry.value.window("screen-route-window")))
        defer { window.teardown(); window.window?.close() }
        window.state.showWorkspace("screen-route")
        window.showWorkspace(requested: "screen-route")
        let pane = try #require(window.content?.panes.values.first)
        AgentHandlers.bind(into: services.registry, context: AppActionContext(services: services))
        let appTab = services.macScreenTabs.open(MacScreenRecord(macID: nil), in: pane, focus: false, byPerson: false)
        #expect(LocalPageTab.page(of: appTab) == .macScreen)
        let before = services.pages.tabIDs(in: pane.paneKey)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: appTab), origin: .cli)
        #expect(services.registry.perform("macScreen.open", invocation: invocation))
        #expect(services.pages.tabIDs(in: pane.paneKey).count == before.count + 1)
    }

    @Test func stopTargetsOneUnfocusedViewerAndNeverAnUnknownTab() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let first = LocalPageTab.makeKey(.macScreen)
        let other = LocalPageTab.makeKey(.macScreen)
        for key in [first, other] {
            services.macScreenPages.prepare(key, record: MacScreenRecord(deviceID: device), byPerson: false)
            _ = services.macScreenPages.makeView(for: key)
        }
        defer { services.macScreenPages.tabClosed(first); services.macScreenPages.tabClosed(other) }
        let firstPane = try #require(services.macScreenPages.tab(first)?.pane)
        let otherPane = try #require(services.macScreenPages.tab(other)?.pane)
        firstPane.model.hub?.phase = .streaming(sessionID: "first", scope: .view)
        otherPane.model.hub?.phase = .streaming(sessionID: "other", scope: .view)
        let actions = MacScreenActions(pages: services.macScreenPages, selectedTab: { other },
                                       providerKey: { id, machine in machine == nil ? id : nil },
                                       open: { _, _, _ in }, refusal: { _ in })
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: first), origin: .cli)
        #expect(actions.viewer(invocation) === firstPane)
        #expect(actions.viewer(ActionInvocation(target: ActionTargetRef(kind: .tab, id: "missing"))) == nil)
        #expect(actions.viewer(invocation.onMachine("wrong-machine")) == nil)
        let registry = ActionRegistry.standard()
        _ = try #require(registry.descriptor(for: "macScreen.stopViewing"))
        actions.bind(into: registry)
        #expect(registry.perform("macScreen.stopViewing", invocation: invocation))
        #expect(firstPane.model.hub?.phase == .ended(reason: "viewer_disconnected"))
        #expect(otherPane.model.hub?.phase == .streaming(sessionID: "other", scope: .view))
        for phase: MacScreenHubPhase in [.idle, .ended(reason: "host_stopped"), .revoked(reason: "permission_revoked"),
                                        .declined(.view), .refused(.notSignedIn, requested: .view), .streamFailed(sessionID: "first", scope: .view)] {
            firstPane.model.hub?.phase = phase
            #expect(actions.viewer(invocation) == nil)
            #expect(!registry.perform("macScreen.stopViewing", invocation: invocation))
            #expect(firstPane.model.hub?.phase == phase)
        }
        for phase: MacScreenHubPhase in [.requesting(.view), .waitingForApproval(sessionID: "first", scope: .view),
                                        .approved(sessionID: "first", scope: .view)] {
            firstPane.model.hub?.phase = phase
            #expect(actions.viewer(invocation) === firstPane)
        }
    }
}
