import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal
import CmuxTerminalCore

@MainActor
@Suite("Terminal surface callback identity")
struct TerminalSurfaceCallbackIdentityTests {
    @Test("replaced runtime callback contexts fail closed")
    func replacedRuntimeCallbackContextFailsClosed() {
        let surface = makeSurface()
        let firstContext = GhosttySurfaceCallbackContext(
            surfaceHost: surface.surfaceView,
            surfaceController: surface,
            terminalLifecycleID: surface.terminalLifecycleId
        )
        surface.surfaceCallbackContext = .passRetained(firstContext)

        #expect(surface.isActiveRuntimeCallbackContext(firstContext))

        let secondContext = GhosttySurfaceCallbackContext(
            surfaceHost: surface.surfaceView,
            surfaceController: surface,
            terminalLifecycleID: surface.terminalLifecycleId
        )
        surface.surfaceCallbackContext?.release()
        surface.surfaceCallbackContext = .passRetained(secondContext)
        defer {
            surface.surfaceCallbackContext?.release()
            surface.surfaceCallbackContext = nil
        }

        #expect(!surface.isActiveRuntimeCallbackContext(firstContext))
        #expect(surface.isActiveRuntimeCallbackContext(secondContext))
    }

    private func makeSurface() -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: TerminalSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(
                    surfaceView: nativeView,
                    paneHost: paneHost
                ),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(
                    interSpawnDelay: .zero
                ),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    agentCommandShimTemporaryDirectory: URL(
                        fileURLWithPath: "/tmp/cmux-terminal-tests",
                        isDirectory: true
                    ),
                    installAgentCommandShims: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }
}
