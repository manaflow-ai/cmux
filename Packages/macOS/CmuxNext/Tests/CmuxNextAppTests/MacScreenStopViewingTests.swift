import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import Foundation
import Testing

/// Stop Viewing Shared Screen (`macScreen.stopViewing`, catalog #42789) has a handler, so a Debug
/// launch whose catalog lists it passes HandlerCoverage instead of trapping (the perf cron's
/// Debug launches at 2c1813fb8ed, 2026-11-14), and it ends a tab's viewer session as the
/// toolbar's Disconnect does.
@MainActor @Suite(.serialized)
struct MacScreenStopViewingTests {
    @Test func everyScreenSharingTabActionHasAHandler() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        AgentHandlers.bind(into: services.registry, context: AppActionContext(services: services))
        let unbound = services.registry.unboundActionIDs(in: HandlerCoverage.categories).filter { $0.rawValue.hasPrefix("macScreen.") }
        #expect(unbound.isEmpty, "unbound: \(unbound)")
    }

    /// Stop Viewing on a device tab ends its session as Disconnect does; any other tab is refused.
    @Test func stopViewingEndsTheTargetedTabsSession() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "stop-viewing-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
        pages.prepare("a", record: MacScreenRecord(deviceID: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"), byPerson: false)
        _ = pages.makeView(for: "a")
        let pane = try #require(pages.tab("a")?.pane)
        let viewer = try #require(pane.model.hub)
        let actions = MacScreenActions(pages: pages, selectedTab: { nil }, providerKey: { id, _ in id },
                                       open: { _, _, _ in }, refusal: { _ in })
        viewer.phase = .streaming(sessionID: "s1", scope: .view)
        #expect(actions.viewer(ActionInvocation(target: ActionTargetRef(kind: .tab, id: "a"))) === pane)
        #expect(actions.viewer(ActionInvocation(target: ActionTargetRef(kind: .tab, id: "other"))) == nil)
        #expect(actions.viewer(ActionInvocation()) == nil, "no tab selected")
        pane.disconnectByPerson()
        #expect(viewer.phase == .ended(reason: MacScreenHubReason.viewerDisconnected.rawValue))
        pages.tabClosed("a")
    }
}
