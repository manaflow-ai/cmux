import AppKit
import Foundation
import GhosttyKit
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

    @Test func agentHibernationSuspendKeepsTeeLeaseUntilNativeFree() async {
        let recorder = TeardownOrderRecorder()
        let surface = makeSurface()
        surface.installRuntimeSurfaceForTesting(fakeRuntimeSurface())
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

        await recorder.waitForEventCount(2)
        #expect(recorder.events == [.nativeFree, .teeLeaseRelease])
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

    private func makeSurface() -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
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
