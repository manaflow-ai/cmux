import AppKit
import CmuxNextActions
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDevices
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

    /// `cmux action run macScreen.open --device X --autoconnect` (a control-socket run, as a CLI read-back of a
    /// release build sends it) opens the tab connecting, with no Connect click: the bound effect asks for `.view` and
    /// confirms the record, so `makeHubPane` resumes the scope. Without `autoconnect`, or with it false, the same run
    /// still opens at Connect. Leo, 2026-11-16: "At least like Linux to Mac".
    @Test func autoconnectOpensASocketRunConnecting() throws {
        let pages = pages()
        let opened = OpenedTabs()
        let actions = MacScreenActions(pages: pages, selectedTab: { nil }, providerKey: { id, _ in id },
                                       open: { record, _, byPerson in
                                           // As the app's open does (AgentHandlers): the tab's record, then its view.
                                           let key = "tab-\(opened.items.count)"
                                           opened.items.append(key)
                                           pages.prepare(key, record: try record(), byPerson: byPerson)
                                           _ = pages.makeView(for: key)
                                       }, refusal: { Issue.record("refused: \($0)") })
        let registry = ActionRegistry.standard()
        actions.bind(into: registry)
        defer { opened.items.forEach(pages.tabClosed) }
        func run(_ autoconnect: ActionValue?) throws -> SessionScope? {
            var arguments: [String: ActionValue] = ["device": .string(device)]
            arguments["autoconnect"] = autoconnect
            var invocation = ActionInvocation(arguments: arguments, origin: .cli)
            invocation.viaControlSocket = true
            #expect(registry.perform("macScreen.open", invocation: invocation))
            let key = try #require(opened.items.last)
            return try #require(pages.tab(key)?.pane?.model.hub).resumeScope
        }
        #expect(try run(nil) == nil, "default off: the tab waits at Connect")
        #expect(try run(.bool(false)) == nil)
        #expect(pages.pendingScopes.isEmpty)
        #expect(try run(.bool(true)) == .view, "autoconnect: the tab connects to view")
        #expect(pages.pendingScopes.isEmpty, "the tab took the scope it asked for")
        #expect(try run(.string("true")) == .view, "--autoconnect=true")
        #expect(opened.items.count == 4)
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

    private let other = "5d1e0f2a-6b7c-4d8e-9f01-23456789abcd"
    private let third = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"

    private func failure(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let failure as ActionFailure { return failure.message } catch { return "\(error)" }
    }

    /// `cmux action run macScreen.open --device mac-mini`: a hub device's name (the Mac's Computer Name) resolves at
    /// the action boundary, without case and, failing that, without punctuation or spacing (a `cmux device list` name).
    @Test func aUniqueDeviceNameResolvesToItsHubID() throws {
        let pages = pages()
        let devices = [HubDevice(id: device, name: "Mac Mini"), HubDevice(id: other, name: "Leo’s Mac Studio")]
        for name in ["Mac Mini", "mac mini", "  MAC MINI ", "mac-mini"] {
            let record = try MacScreenActions.record(ActionInvocation(arguments: ["device": .string(name)], origin: .cli), pages: pages, devices: devices)
            #expect(record.deviceID == device, "\(name)")
        }
        #expect(try MacScreenActions.deviceID(named: "leo-s-mac-studio", among: devices) == other)
        #expect(try MacScreenActions.deviceID(named: device.uppercased(), among: []) == device)
        // A non-person invocation opens the tab at Connect: it asks for no scope.
        #expect(pages.pendingScopes.isEmpty)
    }

    @Test func anAmbiguousNameFailsListingTheDevicesItCouldMean() {
        let devices = [HubDevice(id: device, name: "Studio"), HubDevice(id: other, name: "studio"), HubDevice(id: third, name: "Mac Mini")]
        let message = failure { _ = try MacScreenActions.deviceID(named: "STUDIO", among: devices) }
        #expect(message?.contains("Studio (\(device))") == true)
        #expect(message?.contains("studio (\(other))") == true)
        #expect(message?.contains(third) == false)
        // An exact-case-insensitive match wins over a looser one: "mac-mini" is unique among slugs too.
        let looser = [HubDevice(id: device, name: "mac-mini"), HubDevice(id: other, name: "Mac Mini")]
        #expect((try? MacScreenActions.deviceID(named: "Mac-Mini", among: looser)) == device)
        #expect(failure { _ = try MacScreenActions.deviceID(named: "mac mini!", among: looser) }?.contains(other) == true)
    }

    /// One machine registered several times under one name (a reinstall, an old hub record): the one registration
    /// that is online and shares is the one a person means. Two live ones, or none, stay ambiguous.
    @Test func aNameWithOneLiveRegistrationOpensThatOne() {
        let stale = HubDevice(id: device, name: "studio")
        let live = HubDevice(id: other, name: "studio", macScreenShared: true, online: true)
        let notShared = HubDevice(id: third, name: "studio", online: true)
        #expect((try? MacScreenActions.deviceID(named: "Studio", among: [stale, live, notShared])) == other)
        var second = live
        second.id = third
        #expect(failure { _ = try MacScreenActions.deviceID(named: "Studio", among: [stale, live, second]) } != nil)
        #expect(failure { _ = try MacScreenActions.deviceID(named: "Studio", among: [stale, notShared]) } != nil)
    }

    @Test func anUnknownNameFailsListingEveryDeviceAsNameAndID() {
        let pages = pages()
        let devices = [HubDevice(id: device, name: "Mac Mini"), HubDevice(id: other, name: "Studio")]
        let message = failure {
            _ = try MacScreenActions.record(ActionInvocation(arguments: ["device": .string("office-imac")]), pages: pages, devices: devices)
        }
        #expect(message?.contains("office-imac") == true)
        #expect(message?.contains("Mac Mini (\(device))") == true)
        #expect(message?.contains("Studio (\(other))") == true)
        #expect(message?.contains("Choose a device from Screen Sharing") == false)
        let none = failure { _ = try MacScreenActions.deviceID(named: "office-imac", among: []) }
        #expect(none?.contains("sign in to cmux") == true)
        for value: ActionValue in [.string(""), .string("   "), .int(1)] {
            let missing = failure {
                _ = try MacScreenActions.record(ActionInvocation(arguments: ["device": value]), pages: pages, devices: devices)
            }
            #expect(missing?.contains("Mac Mini (\(device))") == true, "\(value)")
        }
        #expect(pages.pendingScopes.isEmpty)
    }

    @Test func noDeviceStillOpensTheHomePage() throws {
        let record = try MacScreenActions.record(ActionInvocation(), pages: pages(), devices: [HubDevice(id: device, name: "Mac Mini")])
        #expect(record.isHome)
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
        let screenPane = try #require(services.macScreenPages.tab(key)?.pane)
        let viewer = try #require(screenPane.model.hub)
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

/// The tabs an `open` made, in order (autoconnectOpensASocketRunConnecting).
@MainActor private final class OpenedTabs {
    var items: [String] = []
}
