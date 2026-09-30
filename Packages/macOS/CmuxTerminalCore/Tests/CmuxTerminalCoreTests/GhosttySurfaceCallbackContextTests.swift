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
        let terminalLifecycleID = UUID()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            terminalLifecycleID: terminalLifecycleID
        )
        #expect(context.surfaceId == controller.surfaceId)
        #expect(context.terminalLifecycleID == terminalLifecycleID)
        #expect(context.tabId == controller.owningTabId)
    }

    @Test func tabIdFallsBackToHostWhenControllerReleased() {
        let hostTabId = UUID()
        let host = FakeSurfaceHost(hostedTabId: hostTabId)
        var controller: FakeSurfaceController? = FakeSurfaceController()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller!,
            terminalLifecycleID: UUID()
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
            surfaceController: controller,
            terminalLifecycleID: UUID()
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
            surfaceController: controller!,
            terminalLifecycleID: UUID()
        )
        controller = nil
        #expect(context.runtimeSurface == pointer)
    }

    @Test func runtimeSurfaceIsNilWhenEverythingReleased() {
        var controller: FakeSurfaceController? = FakeSurfaceController()
        var host: FakeSurfaceHost? = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host!,
            surfaceController: controller!,
            terminalLifecycleID: UUID()
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
            terminalLifecycleID: UUID(),
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
    func runtimeClipboardInvalidationCancelsOwnedTaskExactlyOnce() async throws {
        let controller = FakeSurfaceController()
        let host = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            terminalLifecycleID: UUID()
        )
        let surface = try #require(ghostty_surface_t(bitPattern: 0x11))
        #expect(context.bindRuntimeClipboardSurface(surface, generation: 7))
        let invalidationCount = AtomicUInt64Generation()
        let taskObservedCancellation = AtomicBooleanGate(false)
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                taskObservedCancellation.storeRelease(true)
            }
        }

        let didRegisterRequest = context.registerRuntimeClipboardRequest(
            id: 17,
            onInvalidation: {
                wasAdmitted,
                completesNativeRequest,
                inputAdmission,
                deferredInputDisposition in
                #expect(wasAdmitted)
                #expect(completesNativeRequest)
                #expect(inputAdmission == .unsequenced(epoch: 7))
                if case .discard = deferredInputDisposition {
                    // Expected for whole-runtime teardown.
                } else {
                    Issue.record("Runtime teardown must discard deferred input")
                }
                _ = invalidationCount.advanceRelaxed()
            }
        )
        #expect(didRegisterRequest)
        #expect(context.commitRuntimeClipboardRequest(17))
        #expect(context.attachRuntimeClipboardTask(task, requestID: 17))
        #expect(
            context.markRuntimeClipboardRequestAdmitted(17)
                == .unsequenced(epoch: 7)
        )

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
    func completedRuntimeClipboardRequestIsNotInvalidated() throws {
        let controller = FakeSurfaceController()
        let host = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            terminalLifecycleID: UUID()
        )
        let surface = try #require(ghostty_surface_t(bitPattern: 0x17))
        #expect(context.bindRuntimeClipboardSurface(surface, generation: 9))
        let invalidationCount = AtomicUInt64Generation()

        let didRegisterRequest = context.registerRuntimeClipboardRequest(
            id: 23,
            onInvalidation: { _, _, _, _ in
                _ = invalidationCount.advanceRelaxed()
            }
        )
        #expect(didRegisterRequest)
        #expect(context.commitRuntimeClipboardRequest(23))
        #expect(context.completeRuntimeClipboardRequest(23))

        context.invalidateRuntimeClipboardRequests(
            completingNativeRequests: true
        )

        #expect(invalidationCount.loadRelaxed() == 0)
    }

    @Test @MainActor
    func invalidationHandlerReclaimsItsRequestExactlyOnce() throws {
        let controller = FakeSurfaceController()
        let host = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            terminalLifecycleID: UUID()
        )
        let surface = try #require(ghostty_surface_t(bitPattern: 0x19))
        #expect(context.bindRuntimeClipboardSurface(surface, generation: 11))
        let invalidationCount = AtomicUInt64Generation()
        let completedNativeRequest = AtomicBooleanGate(false)

        let didRegisterRequest = context.registerRuntimeClipboardRequest(
            id: 25,
            onInvalidation: { _, completesNativeRequest, _, _ in
                _ = invalidationCount.advanceRelaxed()
                completedNativeRequest.storeRelease(completesNativeRequest)
            }
        )
        #expect(didRegisterRequest)
        #expect(context.commitRuntimeClipboardRequest(25))
        let invalidate = context.makeRuntimeClipboardInvalidationHandler(
            for: 25,
            completingNativeRequest: true,
            deferredInputDisposition: .replay
        )

        invalidate()
        invalidate()

        #expect(invalidationCount.loadRelaxed() == 1)
        #expect(completedNativeRequest.loadAcquire())
        #expect(!context.completeRuntimeClipboardRequest(25))
    }

    @Test @MainActor
    func invalidatingUncommittedRequestLeavesNativeReclamationToCallback() throws {
        let controller = FakeSurfaceController()
        let host = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            terminalLifecycleID: UUID()
        )
        let surface = try #require(ghostty_surface_t(bitPattern: 0x1f))
        #expect(context.bindRuntimeClipboardSurface(surface, generation: 13))
        let completedNativeRequest = AtomicBooleanGate(true)

        let didRegisterRequest = context.registerRuntimeClipboardRequest(
            id: 31,
            onInvalidation: { _, completesNativeRequest, _, _ in
                completedNativeRequest.storeRelease(completesNativeRequest)
            }
        )
        #expect(didRegisterRequest)

        context.invalidateRuntimeClipboardRequests(
            completingNativeRequests: true
        )

        #expect(!completedNativeRequest.loadAcquire())
        #expect(!context.commitRuntimeClipboardRequest(31))
    }

    @Test @MainActor
    func runtimeClipboardRegistrationKeepsItsBoundNativeSurface() throws {
        let originalSurface = try #require(ghostty_surface_t(bitPattern: 0x3))
        let replacementSurface = try #require(ghostty_surface_t(bitPattern: 0x4))
        let replacementController = FakeSurfaceController(
            runtimeSurfacePointer: replacementSurface
        )
        let host = FakeSurfaceHost(
            attachedSurfaceController: replacementController
        )
        var originalController: FakeSurfaceController? = FakeSurfaceController(
            runtimeSurfacePointer: originalSurface
        )
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: originalController!,
            terminalLifecycleID: UUID()
        )
        #expect(
            context.bindRuntimeClipboardSurface(
                originalSurface,
                generation: 15
            )
        )
        originalController = nil
        let boundSurfaceAddress = try #require(
            context.runtimeClipboardSurfaceAddress
        )
        #expect(boundSurfaceAddress == UInt(bitPattern: originalSurface))

        let reservedAdmissionCount = AtomicUInt64Generation()
        var invalidatedSurfaceAddress: UInt?
        let didRegisterRequest = context.withRuntimeClipboardPasteIntent {
            context.registerRuntimeClipboardRequest(
                id: 37,
                reservePasteInput: { epoch in
                    #expect(epoch == 15)
                    _ = reservedAdmissionCount.advanceRelaxed()
                    return true
                },
                onInvalidation: { _, _, _, _ in
                    invalidatedSurfaceAddress = context
                        .runtimeClipboardSurfaceAddress
                }
            )
        }
        #expect(didRegisterRequest)
        #expect(context.commitRuntimeClipboardRequest(37))
        #expect(
            !context.bindRuntimeClipboardSurface(
                replacementSurface,
                generation: 17
            )
        )

        context.invalidateRuntimeClipboardRequests(
            completingNativeRequests: true
        )

        #expect(reservedAdmissionCount.loadRelaxed() == 1)
        #expect(invalidatedSurfaceAddress == UInt(bitPattern: originalSurface))
    }

    @Test @MainActor
    func registrationBeforeSurfaceBindingDoesNotReserveAdmission() {
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: FakeSurfaceHost(),
            surfaceController: FakeSurfaceController(),
            terminalLifecycleID: UUID()
        )
        let reservedAdmissionCount = AtomicUInt64Generation()

        let didRegisterRequest = context.withRuntimeClipboardPasteIntent {
            context.registerRuntimeClipboardRequest(
                id: 39,
                reservePasteInput: { _ in
                    _ = reservedAdmissionCount.advanceRelaxed()
                    return true
                },
                onInvalidation: { _, _, _, _ in }
            )
        }
        #expect(!didRegisterRequest)

        #expect(reservedAdmissionCount.loadRelaxed() == 0)
    }

    @Test @MainActor
    func attachingTaskAfterInvalidationRejectsAndCancelsIt() async throws {
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: FakeSurfaceHost(),
            surfaceController: FakeSurfaceController(),
            terminalLifecycleID: UUID()
        )
        let surface = try #require(ghostty_surface_t(bitPattern: 0x29))
        #expect(context.bindRuntimeClipboardSurface(surface, generation: 19))
        let didRegisterRequest = context.registerRuntimeClipboardRequest(
            id: 40,
            onInvalidation: { _, _, _, _ in }
        )
        #expect(didRegisterRequest)
        context.invalidateRuntimeClipboardRequests(
            completingNativeRequests: false
        )
        let observedCancellation = AtomicBooleanGate(false)
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                observedCancellation.storeRelease(true)
            }
        }

        #expect(!context.attachRuntimeClipboardTask(task, requestID: 40))
        await task.value
        #expect(observedCancellation.loadAcquire())
    }

    @Test @MainActor
    func rejectedRuntimeClipboardRegistrationDoesNotReserveAdmission() {
        let controller = FakeSurfaceController()
        let host = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            terminalLifecycleID: UUID()
        )
        context.invalidateRuntimeClipboardRequests(
            completingNativeRequests: false
        )
        let reservedAdmissionCount = AtomicUInt64Generation()

        let didRegisterRequest = context.withRuntimeClipboardPasteIntent {
            context.registerRuntimeClipboardRequest(
                id: 41,
                reservePasteInput: { _ in
                    _ = reservedAdmissionCount.advanceRelaxed()
                    return true
                },
                onInvalidation: { _, _, _, _ in }
            )
        }
        #expect(!didRegisterRequest)

        #expect(reservedAdmissionCount.loadRelaxed() == 0)
    }

    @Test @MainActor
    func synchronousPasteDispatchReservesReadsAcrossSurfaces() throws {
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: FakeSurfaceHost(),
            surfaceController: FakeSurfaceController(),
            terminalLifecycleID: UUID()
        )
        let secondContext = GhosttySurfaceCallbackContext(
            surfaceHost: FakeSurfaceHost(),
            surfaceController: FakeSurfaceController(),
            terminalLifecycleID: UUID()
        )
        let surface = try #require(ghostty_surface_t(bitPattern: 0x2a))
        let secondSurface = try #require(
            ghostty_surface_t(bitPattern: 0x2c)
        )
        #expect(context.bindRuntimeClipboardSurface(surface, generation: 27))
        #expect(
            secondContext.bindRuntimeClipboardSurface(
                secondSurface,
                generation: 29
            )
        )
        let reservedAdmissionCount = AtomicUInt64Generation()

        let didRegisterInitialRequest = secondContext
            .registerRuntimeClipboardRequest(
                id: 1,
                reservePasteInput: { _ in
                    _ = reservedAdmissionCount.advanceRelaxed()
                    return true
                },
                onInvalidation: { _, _, _, _ in }
            )
        #expect(didRegisterInitialRequest)
        #expect(secondContext.commitRuntimeClipboardRequest(1))
        #expect(
            secondContext.markRuntimeClipboardRequestAdmitted(1)
                == .unsequenced(epoch: 29)
        )
        #expect(secondContext.completeRuntimeClipboardRequest(1))

        let acceptedPasteRequests = context.withRuntimeClipboardPasteIntent {
            [
                context.registerRuntimeClipboardRequest(
                    id: 2,
                    reservePasteInput: { epoch in
                        #expect(epoch == 27)
                        _ = reservedAdmissionCount.advanceRelaxed()
                        return true
                    },
                    onInvalidation: { _, _, _, _ in }
                ),
                secondContext.registerRuntimeClipboardRequest(
                    id: 3,
                    reservePasteInput: { epoch in
                        #expect(epoch == 29)
                        _ = reservedAdmissionCount.advanceRelaxed()
                        return true
                    },
                    onInvalidation: { _, _, _, _ in }
                ),
            ]
        }
        #expect(acceptedPasteRequests == [true, true])
        #expect(context.commitRuntimeClipboardRequest(2))
        #expect(
            context.markRuntimeClipboardRequestAdmitted(2)
                == .reserved(epoch: 27)
        )
        #expect(context.completeRuntimeClipboardRequest(2))
        #expect(secondContext.commitRuntimeClipboardRequest(3))
        #expect(
            secondContext.markRuntimeClipboardRequestAdmitted(3)
                == .reserved(epoch: 29)
        )
        #expect(secondContext.completeRuntimeClipboardRequest(3))
        #expect(reservedAdmissionCount.loadRelaxed() == 2)
    }

    @Test @MainActor
    func runtimeClipboardRegistrationIsBoundedBeforeReservation() throws {
        let controller = FakeSurfaceController()
        let host = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            terminalLifecycleID: UUID(),
            maximumRuntimeClipboardRequests: 2
        )
        let surface = try #require(ghostty_surface_t(bitPattern: 0x2b))
        #expect(context.bindRuntimeClipboardSurface(surface, generation: 21))
        let reservedAdmissionCount = AtomicUInt64Generation()

        for id in 1...3 {
            let accepted = context.withRuntimeClipboardPasteIntent {
                context.registerRuntimeClipboardRequest(
                    id: UInt(id),
                    reservePasteInput: { _ in
                        _ = reservedAdmissionCount.advanceRelaxed()
                        return true
                    },
                    onInvalidation: { _, _, _, _ in }
                )
            }
            #expect(accepted == (id <= 2))
        }

        #expect(reservedAdmissionCount.loadRelaxed() == 2)
        context.invalidateRuntimeClipboardRequests(
            completingNativeRequests: false
        )
    }

    @Test @MainActor
    func failedRuntimeClipboardReservationDoesNotConsumeCapacity() throws {
        let controller = FakeSurfaceController()
        let host = FakeSurfaceHost()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            terminalLifecycleID: UUID(),
            maximumRuntimeClipboardRequests: 1
        )
        let surface = try #require(ghostty_surface_t(bitPattern: 0x35))
        #expect(context.bindRuntimeClipboardSurface(surface, generation: 23))

        let didRegisterRejectedRequest =
            context.withRuntimeClipboardPasteIntent {
                context.registerRuntimeClipboardRequest(
                    id: 1,
                    reservePasteInput: { _ in false },
                    onInvalidation: { _, _, _, _ in }
                )
            }
        #expect(!didRegisterRejectedRequest)
        let didRegisterReplacementRequest =
            context.registerRuntimeClipboardRequest(
                id: 2,
                onInvalidation: { _, _, _, _ in }
            )
        #expect(didRegisterReplacementRequest)

        context.invalidateRuntimeClipboardRequests(
            completingNativeRequests: false
        )
    }
}
