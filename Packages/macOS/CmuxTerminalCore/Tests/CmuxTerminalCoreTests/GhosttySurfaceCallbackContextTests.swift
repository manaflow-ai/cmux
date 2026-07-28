import Foundation
import Testing
import CmuxFoundation
import CmuxTerminalCore
import GhosttyKit

private final class FakeSurfaceController: TerminalSurfaceControlling {
    let surfaceId: UUID
    let owningTabId: UUID
    var runtimeSurfacePointer: ghostty_surface_t?

    init(
        surfaceId: UUID = UUID(),
        owningTabId: UUID = UUID(),
        runtimeSurfacePointer: ghostty_surface_t? = nil
    ) {
        self.surfaceId = surfaceId
        self.owningTabId = owningTabId
        self.runtimeSurfacePointer = runtimeSurfacePointer
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

    @Test func rendererRepairSignalCoalescesUntilRearmed() {
        let controller = FakeSurfaceController()
        let host = FakeSurfaceHost()
        let expectedSurfaceID = controller.surfaceId
        let callbackCount = AtomicUInt64Generation()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            rendererMailboxDidDrain: { surfaceID in
                #expect(surfaceID == expectedSurfaceID)
                _ = callbackCount.advanceRelaxed()
            }
        )

        context.rendererMailboxDidDrain()
        context.armRendererPresentationRepair()
        context.rendererMailboxDidDrain()
        context.rendererMailboxDidDrain()
        context.armRendererPresentationRepair()
        context.cancelRendererPresentationRepair()
        context.rendererMailboxDidDrain()

        #expect(callbackCount.loadRelaxed() == 1)
    }

    @Test @MainActor
    func runtimeClipboardInvalidationCancelsOwnedTaskExactlyOnce() async {
        let controller = FakeSurfaceController()
        let host = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller
        )
        let invalidationCount = AtomicUInt64Generation()
        let taskObservedCancellation = AtomicBooleanGate(false)
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                taskObservedCancellation.storeRelease(true)
            }
        }

        #expect(context.registerRuntimeClipboardRequest(
            id: 17,
            onInvalidation: { wasAdmitted, completesNativeRequest in
                #expect(wasAdmitted)
                #expect(completesNativeRequest)
                _ = invalidationCount.advanceRelaxed()
            }
        ))
        #expect(context.attachRuntimeClipboardTask(task, requestID: 17))
        context.markRuntimeClipboardRequestAdmitted(17)

        context.invalidateRuntimeClipboardRequests(
            completingNativeRequests: true
        )
        await task.value
        context.invalidateRuntimeClipboardRequests(
            completingNativeRequests: true
        )

        #expect(taskObservedCancellation.loadAcquire())
        #expect(invalidationCount.loadRelaxed() == 1)
        #expect(!context.completeRuntimeClipboardRequest(17))
    }

    @Test @MainActor
    func completedRuntimeClipboardRequestIsNotInvalidated() {
        let controller = FakeSurfaceController()
        let host = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller
        )
        let invalidationCount = AtomicUInt64Generation()

        #expect(context.registerRuntimeClipboardRequest(
            id: 23,
            onInvalidation: { _, _ in
                _ = invalidationCount.advanceRelaxed()
            }
        ))
        #expect(context.completeRuntimeClipboardRequest(23))

        context.invalidateRuntimeClipboardRequests(
            completingNativeRequests: true
        )

        #expect(invalidationCount.loadRelaxed() == 0)
    }
}
