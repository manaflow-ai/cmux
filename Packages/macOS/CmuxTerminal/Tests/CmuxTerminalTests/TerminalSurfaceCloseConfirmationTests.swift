import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_runtime_stubs_reset")
private func resetGhosttyRuntimeStubs()

@_silgen_name("cmux_test_ghostty_runtime_stubs_set_close_state")
private func setGhosttyCloseState(_ needsConfirm: Bool, _ foregroundPID: UInt64, _ ttyName: UnsafePointer<CChar>?)

@_silgen_name("cmux_test_ghostty_tty_name_call_count")
private func ghosttyTTYNameCallCount() -> UInt32

@MainActor
@Suite(.serialized) struct TerminalSurfaceCloseConfirmationTests {
    @Test func controllingTTYNameIsReadOncePerRuntimeLifecycle() {
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        resetGhosttyRuntimeStubs()
        defer {
            resetGhosttyRuntimeStubs()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        "/dev/null".withCString { ttyName in
            setGhosttyCloseState(false, 0, ttyName)
            surface.installRuntimeSurfaceForTesting(runtimeSurface)

            #expect(surface.controllingTTYName() == "/dev/null")
            #expect(surface.controllingTTYName() == "/dev/null")
        }

        #expect(
            ghosttyTTYNameCallCount() == 1,
            "PID routing must reuse terminal-lifecycle TTY identity instead of probing every surface"
        )
    }

    @Test func liveSurfaceWithoutPidOrTtyDoesNotRequireConfirmation() {
        let surface = makeSurface()
        let runtimeSurface = fakeRuntimeSurface()
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        resetGhosttyRuntimeStubs()
        setGhosttyCloseState(true, 0, nil)
        defer {
            resetGhosttyRuntimeStubs()
            surface.releaseSurfaceForTesting()
        }

        #expect(!surface.needsConfirmClose())
    }

    @Test func liveSurfaceWithForegroundPidPreservesGhosttyConfirmation() {
        let surface = makeSurface()
        let runtimeSurface = fakeRuntimeSurface()
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        resetGhosttyRuntimeStubs()
        setGhosttyCloseState(true, 42, nil)
        defer {
            resetGhosttyRuntimeStubs()
            surface.releaseSurfaceForTesting()
        }

        #expect(surface.needsConfirmClose())
    }

    @Test func liveSurfaceWithTtyPreservesGhosttyConfirmation() {
        let surface = makeSurface()
        let runtimeSurface = fakeRuntimeSurface()
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        resetGhosttyRuntimeStubs()
        "/dev/ttys123".withCString { ttyName in
            setGhosttyCloseState(true, 0, ttyName)
            #expect(surface.needsConfirmClose())
        }
        resetGhosttyRuntimeStubs()
        surface.releaseSurfaceForTesting()
    }

    @Test func pendingStartupCommandPreservesGhosttyConfirmationBeforePidOrTty() {
        let surface = makeSurface(initialCommand: "sleep 10")
        let runtimeSurface = fakeRuntimeSurface()
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        resetGhosttyRuntimeStubs()
        setGhosttyCloseState(true, 0, nil)
        defer {
            resetGhosttyRuntimeStubs()
            surface.releaseSurfaceForTesting()
        }

        #expect(surface.needsConfirmClose())
    }

    @Test func runtimeGenerationAdvancesWhenAllocatorReusesPointer() {
        let surface = makeSurface()
        let runtimeSurface = fakeRuntimeSurface()
        let initialGeneration = surface.runtimeSurfaceGeneration

        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        let firstLifetime = surface.runtimeSurfaceGeneration
        surface.releaseSurfaceForTesting()
        let releasedLifetime = surface.runtimeSurfaceGeneration
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        let reusedPointerLifetime = surface.runtimeSurfaceGeneration
        surface.releaseSurfaceForTesting()

        #expect(firstLifetime == initialGeneration &+ 1)
        #expect(releasedLifetime == firstLifetime &+ 1)
        #expect(reusedPointerLifetime == releasedLifetime &+ 1)
    }

    private func makeSurface(
        initialCommand: String? = nil,
        registry: FakeSurfaceRegistry = FakeSurfaceRegistry()
    ) -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialCommand: initialCommand,
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
        UnsafeMutableRawPointer(bitPattern: 0x7540)!
    }
}
