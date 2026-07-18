import AppKit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

private actor HibernationValidationGate {
    private var validationStarted = false
    private var validationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var validationResultContinuation: CheckedContinuation<Bool, Never>?

    func validate() async -> Bool {
        validationStarted = true
        let waiters = validationStartWaiters
        validationStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            validationResultContinuation = continuation
        }
    }

    func waitUntilValidationStarts() async {
        guard !validationStarted else { return }
        await withCheckedContinuation { continuation in
            validationStartWaiters.append(continuation)
        }
    }

    func resolveValidation(_ result: Bool) {
        validationResultContinuation?.resume(returning: result)
        validationResultContinuation = nil
    }
}

private final class HibernationSurfaceInvalidator: @unchecked Sendable {
    private weak var surface: TerminalSurface?

    @MainActor
    init(surface: TerminalSurface) {
        self.surface = surface
    }

    func invalidate() async {
        await MainActor.run {
            self.surface?.invalidateProvisionalAgentHibernation()
        }
    }
}

private final class HibernationSurfaceRegistry: TerminalSurfaceRegistering, @unchecked Sendable {
    private var runtimeOwners: [UInt: UUID] = [:]

    var topologyGeneration: UInt64 { 0 }
    func register(_ surface: any TerminalSurfacing) {}
    func unregister(_ surface: any TerminalSurfacing) {}
    func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        runtimeOwners[UInt(bitPattern: surface)] = ownerId
    }
    func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        let key = UInt(bitPattern: surface)
        guard runtimeOwners[key] == ownerId else { return }
        runtimeOwners.removeValue(forKey: key)
    }
    func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID? {
        runtimeOwners[UInt(bitPattern: surface)]
    }
    func surface(id: UUID) -> (any TerminalSurfacing)? { nil }
    func isRightSidebarDockSurface(id: UUID) -> Bool { false }
    func updateFocusPlacement(id: UUID, _ placement: TerminalSurfaceFocusPlacement) {}
    func allSurfaces() -> [any TerminalSurfacing] { [] }
}

/// The ghostty PTY tee callback and the MANUAL-mode `io_write_cb` fire on
/// ghostty's IO threads until `ghostty_surface_free` joins those threads. The
/// retained callback userdata (the byte-tee lease's context and the manual IO
/// write box) must therefore stay alive until the native free has completed;
/// releasing earlier is a use-after-free window on the IO reader thread.
///
/// These tests pin that ordering on every teardown path that defers the
/// native free to the runtime teardown coordinator.
@MainActor
@Suite(.serialized) struct TerminalSurfaceTeardownCallbackLifetimeTests {
    @Test func teardownSurfaceKeepsTeeLeaseUntilNativeFree() async {
        let recorder = TeardownOrderRecorder()
        let surface = makeSurface()
        surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
        surface.mobileByteTeeLease = RecordingTerminalByteTeeLease(recorder: recorder)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        surface.teardownSurface()

        // Still on the same main-actor turn: the lease release is only legal
        // after the native free, which has not been awaited yet.
        #expect(
            !recorder.events.contains(.teeLeaseRelease),
            "tee lease was released before the native free; the IO reader thread can still fire the tee callback"
        )

        await recorder.waitForEventCount(2)
        #expect(recorder.events == [.nativeFree, .teeLeaseRelease])
    }

    @Test func agentHibernationSuspendReturnsOnlyAfterNativeFreeAndUserdataRelease() async {
        let recorder = TeardownOrderRecorder()
        let surface = makeSurface()
        surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
        let generation = surface.runtimeSurfaceGeneration
        surface.mobileByteTeeLease = RecordingTerminalByteTeeLease(recorder: recorder)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        let didSuspend = await surface.suspendRuntimeSurfaceForAgentHibernation(
            reason: "test.hibernate",
            finalValidation: {
                recorder.record(.finalValidation)
                return true
            }
        )

        #expect(didSuspend)
        #expect(recorder.events == [.finalValidation, .nativeFree, .teeLeaseRelease])
        #expect(surface.surface == nil)
        #expect(surface.runtimeSurfaceGeneration == generation &+ 1)
        #expect(surface.runtimeSurfaceSuspendedForAgentHibernation)
    }

    @Test func rejectedAgentHibernationRestoresExactRuntimeOwnershipWithoutChangingGeneration() async {
        let recorder = TeardownOrderRecorder()
        let surface = makeSurface()
        let runtimeSurface = fakeRuntimeSurface()
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        let generation = surface.runtimeSurfaceGeneration
        let callbackContext = Unmanaged.passRetained(
            GhosttySurfaceCallbackContext(surfaceHost: surface.surfaceView, surfaceController: surface)
        )
        let manualIOContext = Unmanaged.passRetained(TerminalManualIOWriteBox(onWrite: { _ in }))
        let teeLease = RecordingTerminalByteTeeLease(recorder: recorder)
        surface.surfaceCallbackContext = callbackContext
        surface.manualIOContext = manualIOContext
        surface.mobileByteTeeLease = teeLease
        #expect(surface.portalLifecycleState == .live)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        let didSuspend = await surface.suspendRuntimeSurfaceForAgentHibernation(
            reason: "test.hibernate.rejected",
            finalValidation: {
                recorder.record(.finalValidation)
                return false
            }
        )

        #expect(!didSuspend)
        #expect(surface.portalLifecycleState == .live)
        #expect(surface.teardownRequestReason == nil)
        #expect(surface.surface == runtimeSurface)
        #expect(surface.runtimeSurfaceGeneration == generation)
        #expect(surface.surfaceCallbackContext?.toOpaque() == callbackContext.toOpaque())
        #expect(surface.manualIOContext?.toOpaque() == manualIOContext.toOpaque())
        #expect(surface.mobileByteTeeLease === teeLease)
        #expect(!surface.runtimeSurfaceSuspendedForAgentHibernation)
        #expect(recorder.events == [.finalValidation])

        surface.teardownSurface()
        await recorder.waitForEventCount(3)
        #expect(recorder.events == [.finalValidation, .nativeFree, .teeLeaseRelease])
    }

    @Test func portalCloseDuringRejectedValidationFreesTransferredRuntimeInsteadOfRestoringIt() async {
        let recorder = TeardownOrderRecorder()
        let validationGate = HibernationValidationGate()
        let surface = makeSurface()
        surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
        let generation = surface.runtimeSurfaceGeneration
        surface.mobileByteTeeLease = RecordingTerminalByteTeeLease(recorder: recorder)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        let suspension = Task { @MainActor in
            await surface.suspendRuntimeSurfaceForAgentHibernation(
                reason: "test.hibernate.closeRace",
                finalValidation: {
                    recorder.record(.finalValidation)
                    return await validationGate.validate()
                }
            )
        }
        await validationGate.waitUntilValidationStarts()

        surface.teardownSurface()
        await validationGate.resolveValidation(false)
        let didSuspend = await suspension.value

        #expect(!didSuspend)
        #expect(surface.surface == nil)
        #expect(surface.runtimeSurfaceGeneration == generation &+ 1)
        #expect(!surface.runtimeSurfaceSuspendedForAgentHibernation)
        #expect(recorder.events == [.finalValidation, .nativeFree, .teeLeaseRelease])
    }

    @Test func explicitInputDuringProvisionalHibernationRejectsAndFlushesToRestoredRuntime() async {
        let recorder = TeardownOrderRecorder()
        let validationGate = HibernationValidationGate()
        let registry = HibernationSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { runtimeSurface.deallocate() }
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        let generation = surface.runtimeSurfaceGeneration
        surface.pendingSocketInputFlushOverrideForTesting = { items, bytes in
            #expect(items > 0)
            #expect(bytes > 0)
            recorder.record(.pendingInputFlush)
        }
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            recorder.record(.nativeFree)
        }
        defer {
            surface.pendingSocketInputFlushOverrideForTesting = nil
            TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil
        }

        let suspension = Task { @MainActor in
            await surface.suspendRuntimeSurfaceForAgentHibernation(
                reason: "test.hibernate.inputRace",
                finalValidation: {
                    recorder.record(.finalValidation)
                    return await validationGate.validate()
                }
            )
        }
        await validationGate.waitUntilValidationStarts()

        #expect(surface.portalLifecycleState == .live)
        #expect(surface.sendInputResult("echo preserved\r") == .queued)
        #expect(surface.portalLifecycleState == .live)
        #expect(surface.debugPendingSocketInputForTesting().items > 0)
        await validationGate.resolveValidation(true)
        let didSuspend = await suspension.value
        #expect(surface.portalLifecycleState == .live)
        #expect(surface.teardownRequestReason == nil)

        #expect(!didSuspend)
        #expect(surface.surface == runtimeSurface)
        #expect(surface.runtimeSurfaceGeneration == generation)
        #expect(surface.debugPendingSocketInputForTesting().items == 0)
        #expect(recorder.events == [.finalValidation, .pendingInputFlush])

        surface.runtimeSurfaceFreedOutOfBandForTesting = true
        surface.teardownSurface()
    }

    @Test func lifecycleInvalidationAfterOuterClaimStillRejectsNativeHibernation() async {
        let recorder = TeardownOrderRecorder()
        let registry = HibernationSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { runtimeSurface.deallocate() }
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        let generation = surface.runtimeSurfaceGeneration
        let invalidator = HibernationSurfaceInvalidator(surface: surface)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        let didSuspend = await surface.suspendRuntimeSurfaceForAgentHibernation(
            reason: "test.hibernate.lifecycleAfterOuterClaim",
            finalValidation: {
                // Model the controller token having been claimed, followed by
                // a Workspace shell/lifecycle/PID mutation before the package's
                // last native-free gate.
                recorder.record(.finalValidation)
                await invalidator.invalidate()
                return true
            }
        )

        #expect(!didSuspend)
        #expect(surface.surface == runtimeSurface)
        #expect(surface.runtimeSurfaceGeneration == generation)
        #expect(recorder.events == [.finalValidation])

        surface.runtimeSurfaceFreedOutOfBandForTesting = true
        surface.teardownSurface()
    }

    @Test func explicitInputAfterCommitPointSurvivesForImmediateResume() async {
        let recorder = TeardownOrderRecorder()
        let releaseNativeFree = DispatchSemaphore(value: 0)
        let surface = makeSurface()
        surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            recorder.record(.nativeFree)
            releaseNativeFree.wait()
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        let suspension = Task { @MainActor in
            await surface.suspendRuntimeSurfaceForAgentHibernation(
                reason: "test.hibernate.inputAfterCommit",
                finalValidation: {
                    recorder.record(.finalValidation)
                    return true
                }
            )
        }
        await recorder.waitForEventCount(2)

        #expect(surface.sendNamedKey("enter") == .queued)
        #expect(surface.debugPendingSocketInputForTesting().items == 1)
        releaseNativeFree.signal()

        #expect(await suspension.value)
        #expect(surface.hasPendingInputForAgentHibernationResume)
        #expect(surface.debugPendingSocketInputForTesting().items == 1)
        #expect(recorder.events == [.finalValidation, .nativeFree])
    }

    @Test func resumeCannotReopenRuntimeUntilHibernationFreeCompletes() async {
        let recorder = TeardownOrderRecorder()
        let validationGate = HibernationValidationGate()
        let surface = makeSurface()
        surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
        surface.mobileByteTeeLease = RecordingTerminalByteTeeLease(recorder: recorder)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        let suspension = Task { @MainActor in
            await surface.suspendRuntimeSurfaceForAgentHibernation(
                reason: "test.hibernate.resumeRace",
                finalValidation: {
                    recorder.record(.finalValidation)
                    return await validationGate.validate()
                }
            )
        }
        await validationGate.waitUntilValidationStarts()

        surface.prepareAgentHibernationResume(initialInput: "too early")
        #expect(surface.nextRuntimeInitialInput == nil)

        await validationGate.resolveValidation(true)
        #expect(await suspension.value)
        #expect(surface.runtimeSurfaceSuspendedForAgentHibernation)

        surface.prepareAgentHibernationResume(initialInput: "after free")
        #expect(!surface.runtimeSurfaceSuspendedForAgentHibernation)
        #expect(surface.nextRuntimeInitialInput == "after free")
        #expect(recorder.events == [.finalValidation, .nativeFree, .teeLeaseRelease])
    }

    @Test func restoredHibernationMarkerRequiresLiveModelWithoutNativeRuntime() {
        let restoredSurface = makeSurface()

        #expect(restoredSurface.markRuntimeSurfaceSuspendedForRestoredAgentHibernation())
        #expect(restoredSurface.runtimeSurfaceSuspendedForAgentHibernation)

        let liveSurface = makeSurface()
        liveSurface.installRuntimeSurfaceForTesting(fakeRuntimeSurface())

        #expect(!liveSurface.markRuntimeSurfaceSuspendedForRestoredAgentHibernation())
        #expect(!liveSurface.runtimeSurfaceSuspendedForAgentHibernation)

        liveSurface.runtimeSurfaceFreedOutOfBandForTesting = true
        liveSurface.teardownSurface()
    }

    @Test func deinitKeepsTeeLeaseUntilCoordinatorFree() async {
        let recorder = TeardownOrderRecorder()
        var surface: TerminalSurface? = makeSurface()
        surface?.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
        surface?.mobileByteTeeLease = RecordingTerminalByteTeeLease(recorder: recorder)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        surface = nil

        // deinit enqueues the native free on the teardown coordinator; until
        // that free runs, the tee lease must not have been released.
        #expect(
            !recorder.events.contains(.teeLeaseRelease),
            "deinit released the tee lease inline instead of handing it to the teardown coordinator"
        )

        await recorder.waitForEventCount(2)
        // The native free must land before the tee-lease release: ghostty's IO
        // reader thread can fire the tee callback until the free joins it.
        #expect(recorder.events == [.nativeFree, .teeLeaseRelease])
    }

    @Test func teardownSurfaceKeepsManualIOContextUntilNativeFree() async {
        let recorder = TeardownOrderRecorder()
        let surface = makeSurface()
        surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
        surface.mobileByteTeeLease = RecordingTerminalByteTeeLease(recorder: recorder)
        weak var weakBox: TerminalManualIOWriteBox?
        // Immediately-executed closure so the only remaining strong reference
        // is the retained Unmanaged context handed to the surface.
        ({
            let box = TerminalManualIOWriteBox(onWrite: { _ in })
            weakBox = box
            surface.manualIOContext = Unmanaged.passRetained(box)
        })()
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        surface.teardownSurface()

        #expect(
            weakBox != nil,
            "manual IO write box was released before the native free; ghostty's IO thread can still invoke io_write_cb"
        )

        // The coordinator releases the manual IO context before the tee
        // lease, so the lease event doubles as the completion beacon.
        await recorder.waitForEventCount(2)
        #expect(recorder.events == [.nativeFree, .teeLeaseRelease])
        #expect(weakBox == nil, "manual IO write box must still be released after the native free")
    }

    @Test func coordinatorReleasesTransportedTeeLeaseOnlyAfterFreeCompletes() async {
        let recorder = TeardownOrderRecorder()
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }

        coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.transport",
            surface: surface,
            callbackContext: nil,
            manualIOContext: nil,
            byteTeeLease: RecordingTerminalByteTeeLease(recorder: recorder),
            freeSurface: { _ in
                recorder.record(.nativeFree)
            }
        )

        await recorder.waitForEventCount(2)
        #expect(recorder.events == [.nativeFree, .teeLeaseRelease])
    }

    private func makeSurface(
        registry: any TerminalSurfaceRegistering = FakeSurfaceRegistry()
    ) -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: registry,
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(surfaceView: nativeView, paneHost: paneHost),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    claudeCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
                    installClaudeCommandShim: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }

    private func fakeRuntimeSurface() -> ghostty_surface_t {
        UnsafeMutableRawPointer(bitPattern: 0x7541)!
    }
}
