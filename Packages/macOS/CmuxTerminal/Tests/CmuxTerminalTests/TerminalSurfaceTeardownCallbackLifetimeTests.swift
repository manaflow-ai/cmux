import AppKit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

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
    @Test func explicitTeardownRetiresLogicalRegistryOwnershipExactlyOnce() throws {
        let registry = TerminalSurfaceRegistry()
        var surface: TerminalSurface? = makeSurface(registry: registry)
        let surfaceId = try #require(surface?.id)
        let registeredGeneration = registry.topologyGeneration
        #expect(registry.surface(id: surfaceId) != nil)

        surface?.teardownSurface()
        let teardownGeneration = registry.topologyGeneration
        #expect(registry.surface(id: surfaceId) == nil)
        #expect(teardownGeneration > registeredGeneration)

        surface?.teardownSurface()
        #expect(registry.topologyGeneration == teardownGeneration)

        surface = nil
        #expect(registry.topologyGeneration == teardownGeneration)
    }

    @Test func deinitOnlyTeardownStillRetiresRegistryOwnership() throws {
        let registry = TerminalSurfaceRegistry()
        var surface: TerminalSurface? = makeSurface(registry: registry)
        let surfaceId = try #require(surface?.id)
        let registeredGeneration = registry.topologyGeneration

        surface = nil

        #expect(registry.surface(id: surfaceId) == nil)
        #expect(registry.topologyGeneration > registeredGeneration)
    }

    @Test func cancellingEventWaitReturnsWithoutWaitingForDeadline() async {
        let recorder = TeardownOrderRecorder()
        let wait = Task {
            await recorder.waitForEventCount(1, timeout: .seconds(60))
        }

        await recorder.waitUntilEventWaiterIsRegistered()
        wait.cancel()

        #expect(await wait.value == false)
    }

    @Test func surfaceFreeGateDoesNotInterceptAnotherRuntimeSurface() {
        let gatedSurface = fakeRuntimeSurface()
        let unrelatedSurface = UnsafeMutableRawPointer(bitPattern: 0x7542)!
        cmux_test_ghostty_surface_free_blocking_begin(gatedSurface)
        defer {
            cmux_test_ghostty_surface_free_release()
            cmux_test_ghostty_surface_free_blocking_reset()
        }

        ghostty_surface_free(unrelatedSurface)

        #expect(
            !cmux_test_ghostty_surface_free_blocking_did_start(),
            "the test gate intercepted a different runtime surface"
        )
    }

    @Test func teardownSurfaceKeepsMainActorResponsiveWhileNativeFreeIsBlocked() async {
        let surface = makeSurface()
        let runtimeSurface = fakeRuntimeSurface()
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        cmux_test_ghostty_surface_free_blocking_begin(runtimeSurface)
        defer {
            cmux_test_ghostty_surface_free_release()
            cmux_test_ghostty_surface_free_blocking_reset()
        }

        let probeResult = AsyncStream<Bool>.makeStream()
        DispatchQueue.global(qos: .userInitiated).async {
            guard cmux_test_ghostty_surface_free_wait_until_started() else {
                probeResult.continuation.yield(false)
                probeResult.continuation.finish()
                return
            }

            Task { @MainActor in
                let nativeFreeIsStillBlocked =
                    cmux_test_ghostty_surface_free_blocking_is_active()
                cmux_test_ghostty_surface_free_release()
                probeResult.continuation.yield(nativeFreeIsStillBlocked)
                probeResult.continuation.finish()
            }
        }

        surface.teardownSurface()

        var probeResultIterator = probeResult.stream.makeAsyncIterator()
        #expect(
            await probeResultIterator.next() == true,
            "explicit teardown did not start native free while keeping the main actor responsive"
        )
    }

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

        let completed = await recorder.waitForEventCount(2)
        #expect(completed, "timed out waiting for native free and tee-lease release")
        #expect(recorder.events == [.nativeFree, .teeLeaseRelease])
    }

    @Test func agentHibernationSuspendKeepsTeeLeaseUntilNativeFree() async {
        let recorder = TeardownOrderRecorder()
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        defer { runtimeSurface.deallocate() }
        surface.mobileByteTeeLease = RecordingTerminalByteTeeLease(recorder: recorder)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            recorder.record(.nativeFree)
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        surface.suspendRuntimeSurfaceForAgentHibernation(reason: "test.hibernate")

        #expect(
            !recorder.events.contains(.teeLeaseRelease),
            "tee lease was released before the native free; the IO reader thread can still fire the tee callback"
        )

        let completed = await recorder.waitForEventCount(2)
        #expect(completed, "timed out waiting for native free and tee-lease release")
        #expect(recorder.events == [.nativeFree, .teeLeaseRelease])
    }

    @Test func agentHibernationEndsCurrentTerminalProcessGeneration() {
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let originalLifecycleID = surface.terminalLifecycleId

        #expect(registry.isCurrentSurface(
            id: surface.id,
            terminalLifecycleID: originalLifecycleID
        ))
        #expect(surface.suspendRuntimeSurfaceForAgentHibernation(
            reason: "test.lifecycle"
        ))

        let replacementLifecycleID = surface.terminalLifecycleId
        #expect(replacementLifecycleID != originalLifecycleID)
        #expect(!registry.isCurrentSurface(
            id: surface.id,
            terminalLifecycleID: originalLifecycleID
        ))
        #expect(registry.isCurrentSurface(
            id: surface.id,
            terminalLifecycleID: replacementLifecycleID
        ))
        #expect(
            surface.startupEnvironmentValue(
                "CMUX_TERMINAL_LIFECYCLE_ID"
            ) == replacementLifecycleID.uuidString
        )
    }

    @Test func agentHibernationResumeWaitsForNativeFreeCompletion() async {
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        defer { runtimeSurface.deallocate() }
        let freeStarted = AsyncStream<Void>.makeStream()
        let allowFree = DispatchSemaphore(value: 0)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            freeStarted.continuation.yield()
            allowFree.wait()
        }
        defer {
            allowFree.signal()
            TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil
        }

        surface.suspendRuntimeSurfaceForAgentHibernation(reason: "test.hibernate")
        var freeStartedIterator = freeStarted.stream.makeAsyncIterator()
        _ = await freeStartedIterator.next()

        #expect(!surface.prepareAgentHibernationResume(initialInput: nil))

        allowFree.signal()
        #expect(await surface.waitForAgentHibernationRuntimeTeardown(timeout: .seconds(1)))
        #expect(surface.prepareAgentHibernationResume(initialInput: nil))
        freeStarted.continuation.finish()
    }

    @Test func hibernationAdmissionFailurePreservesLiveRuntimeSurface() throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let firstReservation = try #require(
            coordinator.reserveIsolatedHibernationTeardown()
        )
        let secondReservation = try #require(
            coordinator.reserveIsolatedHibernationTeardown()
        )
        defer {
            coordinator.cancelIsolatedHibernationTeardown(firstReservation)
            coordinator.cancelIsolatedHibernationTeardown(secondReservation)
        }

        let surface = makeSurface(runtimeTeardown: coordinator)
        surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        #expect(
            surface.suspendRuntimeSurfaceForAgentHibernation(
                reason: "test.admissionFailure"
            ) == false
        )
        #expect(surface.hasLiveSurface)

        surface.teardownSurface()
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

        let completed = await recorder.waitForEventCount(2)
        #expect(completed, "timed out waiting for native free and tee-lease release")
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
        let completed = await recorder.waitForEventCount(2)
        #expect(completed, "timed out waiting for native free and tee-lease release")
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

        let completed = await recorder.waitForEventCount(2)
        #expect(completed, "timed out waiting for native free and tee-lease release")
        #expect(recorder.events == [.nativeFree, .teeLeaseRelease])
    }

    private func makeSurface(
        registry: any TerminalSurfaceRegistering = FakeSurfaceRegistry(),
        runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator =
            TerminalSurfaceRuntimeTeardownCoordinator()
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
                runtimeTeardown: runtimeTeardown,
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
                    installAgentCommandShims: { _, _, _ in nil },
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
