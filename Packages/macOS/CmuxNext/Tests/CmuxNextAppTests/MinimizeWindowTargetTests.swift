import AppKit
@testable import CmuxNextApp
import CmuxNextActions
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// `minimizeWindow --target window:<id>` (an agent's `cmux` call, the hidden-tab matrix) minimizes
/// the window it names, not the active one: it minimized whichever window was in front, so a
/// background window never minimized and the person's own window went to the Dock.
@MainActor @Suite(.serialized, .closesItsWindows) struct MinimizeWindowTargetTests {
    @Test func minimizeWindowMinimizesItsTargetNotTheActiveWindow() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: PlacementStaleRowsTests.tree(["front", "back"], personal: ["front", "back"]))
        let front = try #require(services.windows.openWindow(workspaces: ["front"], frame: CGRect(x: 120, y: 120, width: 800, height: 520)))
        let back = try #require(services.windows.openWindow(workspaces: ["back"], frame: CGRect(x: 180, y: 160, width: 800, height: 520)))
        let frontWindow = try #require(front.window), backWindow = try #require(back.window)
        defer {
            for controller in [front, back] {
                controller.window?.deminiaturize(nil)
                controller.teardown()
                controller.window?.close()
            }
        }
        // Minimizing needs windows on a screen; the test orders them in itself (the app does not here).
        backWindow.orderFront(nil)
        frontWindow.orderFront(nil)
        services.windows.didActivate(front)
        try #require(services.windows.active === front)

        let target = ActionInvocation(target: ActionTargetRef(kind: .window, id: back.state.id))
        #expect(services.registry.perform("minimizeWindow", invocation: target))
        try await PinnedPageTests.until({ backWindow.isMiniaturized || frontWindow.isMiniaturized }, within: .seconds(10)) {
            "neither window minimized"
        }
        #expect(backWindow.isMiniaturized, "the targeted window did not minimize")
        #expect(!frontWindow.isMiniaturized, "the active window minimized in place of the target")
    }
}
