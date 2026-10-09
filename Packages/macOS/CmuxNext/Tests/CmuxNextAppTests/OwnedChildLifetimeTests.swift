import AppKit
import Testing
@testable import CmuxNextApp

/// Children that keep an unowned back-reference to their owner
/// (crash-allowlist.json: "owned child, nested lifetime") end with it, and the
/// app's services, owner of most of them, are held by the explicit process root.
@MainActor @Suite struct OwnedChildLifetimeTests {
    /// crash-allowlist.json: "owner is the explicit process root AppServices".
    /// The root holds the services it adopts for the life of the process, so a
    /// child of the services can never outlive them.
    @Test func theProcessRootHoldsTheServicesItAdopts() {
        let root = AppProcessRoot()
        weak var weakServices: AppServices?
        do {
            let services = AppServices(environment: AppEnvironment.current([:]))
            weakServices = services
            root.adopt(services)
        }
        #expect(weakServices != nil)
        #expect(root.services === weakServices)
    }

    @Test func screenBarEndsWithItsWorkspaceContent() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try BridgeTreeFixture.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        weak var weakContent: WorkspaceContentController?
        weak var weakBar: ScreenBarController?
        do {
            let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
            weakContent = content
            weakBar = content.screenBar
            content.teardown()
        }
        #expect(weakContent == nil)
        #expect(weakBar == nil)
        withExtendedLifetime(state) {}
    }

    @Test func focusApplierEndsWithItsWindowController() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try BridgeTreeFixture.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        weak var weakController: WindowController?
        weak var weakApplier: FocusEffectApplier?
        try autoreleasepool {
            let controller = WindowController(state: WindowState(workspaceID: workspace.id), services: services, frame: nil)
            weakController = controller
            weakApplier = controller.focusApplier
            let window = try #require(controller.window)
            window.isReleasedWhenClosed = false
            controller.teardown()
            window.close()
        }
        #expect(weakController == nil)
        #expect(weakApplier == nil)
    }

    @Test func overlayLayerAndDividerCatchersEndWithTheirWindow() {
        weak var weakWindow: ShellWindow?
        weak var weakOverlay: WindowOverlayLayer?
        weak var weakCatchers: DividerMouseCatchers?
        autoreleasepool {
            let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            weakWindow = window
            weakOverlay = window.overlayLayer
            weakCatchers = window.overlayLayer.catchers
            window.overlayLayer.teardown()
        }
        #expect(weakWindow == nil)
        #expect(weakOverlay == nil)
        #expect(weakCatchers == nil)
    }
}
