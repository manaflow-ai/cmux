import Foundation
import Testing
import CmuxTerminalCore
import GhosttyKit

private final class FakeSurfaceController: TerminalSurfaceControlling {
    let surfaceId: UUID
    let owningTabId: UUID
    var runtimeSurfacePointer: ghostty_surface_t?
    var waitAfterCommand: Bool

    init(
        surfaceId: UUID = UUID(),
        owningTabId: UUID = UUID(),
        runtimeSurfacePointer: ghostty_surface_t? = nil,
        waitAfterCommand: Bool = false
    ) {
        self.surfaceId = surfaceId
        self.owningTabId = owningTabId
        self.runtimeSurfacePointer = runtimeSurfacePointer
        self.waitAfterCommand = waitAfterCommand
    }
}

private final class FakeSurfaceHost: TerminalSurfaceHosting {
    var hostedTabId: UUID?
    var attachedSurfaceController: (any TerminalSurfaceControlling)?

    init(
        hostedTabId: UUID? = nil,
        attachedSurfaceController: (any TerminalSurfaceControlling)? = nil
    ) {
        self.hostedTabId = hostedTabId
        self.attachedSurfaceController = attachedSurfaceController
    }
}

@Suite struct GhosttySurfaceCallbackContextTests {
    @Test func capturesSurfaceIdentityAtCreation() {
        let controller = FakeSurfaceController()
        let host = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller
        )
        #expect(context.surfaceId == controller.surfaceId)
        #expect(context.tabId == controller.owningTabId)
    }

    @Test func tabIdFallsBackToHostWhenControllerReleased() {
        let hostTabId = UUID()
        let host = FakeSurfaceHost(hostedTabId: hostTabId)
        var controller: FakeSurfaceController? = FakeSurfaceController()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller!
        )
        controller = nil
        #expect(context.tabId == hostTabId)
    }

    @Test func runtimeSurfaceReadsControllerFirst() {
        let pointer = ghostty_surface_t(bitPattern: 0x1)
        let controller = FakeSurfaceController(runtimeSurfacePointer: pointer)
        let host = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller
        )
        #expect(context.runtimeSurface == pointer)
    }

    @Test func runtimeSurfaceFallsBackToHostAttachedController() {
        let pointer = ghostty_surface_t(bitPattern: 0x2)
        let attached = FakeSurfaceController(runtimeSurfacePointer: pointer)
        let host = FakeSurfaceHost(attachedSurfaceController: attached)
        var controller: FakeSurfaceController? = FakeSurfaceController()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller!
        )
        controller = nil
        #expect(context.runtimeSurface == pointer)
    }

    @Test func runtimeSurfaceIsNilWhenEverythingReleased() {
        var controller: FakeSurfaceController? = FakeSurfaceController()
        var host: FakeSurfaceHost? = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host!,
            surfaceController: controller!
        )
        controller = nil
        host = nil
        #expect(context.runtimeSurface == nil)
        #expect(context.tabId == nil)
    }
}
