import AppKit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_renderer_realized_begin")
private func beginOcclusionTracking(_ surface: UnsafeMutableRawPointer)

@_silgen_name("cmux_test_ghostty_renderer_realized_reset")
private func resetOcclusionTracking()

@_silgen_name("cmux_test_ghostty_occlusion_visible")
private func ghosttyOcclusionVisible() -> Bool

/// Ghostty's renderer thread starts every surface at `visible = true` and only
/// reacts to visibility *transitions*. A surface that Ghostty believes is
/// visible keeps its `CVDisplayLink` free to run at the display refresh rate,
/// waking its renderer thread ~120x/sec for a pane nobody can see.
///
/// cmux creates surfaces for background workspaces lazily, so the portal's
/// `setOcclusion(false)` routinely lands while the runtime surface is still nil.
/// These tests pin that such a request is not lost.
@MainActor
@Suite(.serialized) struct TerminalSurfaceOcclusionReplayTests {
    @Test func occlusionRequestedBeforeRuntimeExistsReachesGhosttyOnCreation() {
        let surface = makeSurface()
        let runtime = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        beginOcclusionTracking(runtime)
        defer {
            surface.releaseSurfaceForTesting()
            runtime.deallocate()
            resetOcclusionTracking()
        }

        // The portal hides the pane before its runtime surface has been created.
        surface.setOcclusion(false)
        #expect(ghosttyOcclusionVisible(), "no runtime surface yet, so Ghostty cannot have been told")

        // Runtime surface comes up later; createSurface replays the desired state.
        surface.installRuntimeSurfaceForTesting(runtime)
        surface.replayDesiredOcclusionToRuntime()

        #expect(!ghosttyOcclusionVisible(), "hidden pane must reach Ghostty as occluded")
    }

    @Test func visibleSurfaceIsNotOccludedByTheReplay() {
        let surface = makeSurface()
        let runtime = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        beginOcclusionTracking(runtime)
        defer {
            surface.releaseSurfaceForTesting()
            runtime.deallocate()
            resetOcclusionTracking()
        }

        surface.setOcclusion(true)
        surface.installRuntimeSurfaceForTesting(runtime)
        surface.replayDesiredOcclusionToRuntime()

        #expect(ghosttyOcclusionVisible(), "an on-screen pane must not be occluded by the replay")
    }

    @Test func recreatedRuntimeSurfaceRelearnsOcclusion() {
        let surface = makeSurface()
        let first = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let second = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer {
            surface.releaseSurfaceForTesting()
            first.deallocate()
            second.deallocate()
            resetOcclusionTracking()
        }

        beginOcclusionTracking(first)
        surface.installRuntimeSurfaceForTesting(first)
        surface.setOcclusion(false)
        #expect(!ghosttyOcclusionVisible())

        // A replacement runtime surface starts from Ghostty's visible default, so
        // the dedupe cache from the previous one must not suppress the re-push.
        resetOcclusionTracking()
        beginOcclusionTracking(second)
        surface.installRuntimeSurfaceForTesting(second)
        surface.replayDesiredOcclusionToRuntime()

        #expect(!ghosttyOcclusionVisible(), "recreated surface must relearn that it is hidden")
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
}
