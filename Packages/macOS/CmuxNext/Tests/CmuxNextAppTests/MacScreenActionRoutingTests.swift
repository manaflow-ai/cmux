import AppKit
import CmuxNextActions
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
        let record = try ActionRunScope.$current.withValueInTask(ActionRunScope(origin: origin, allowsViewChange: true)) {
            try MacScreenActions.record(invocation, pages: pages)
        }
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
    }
}
