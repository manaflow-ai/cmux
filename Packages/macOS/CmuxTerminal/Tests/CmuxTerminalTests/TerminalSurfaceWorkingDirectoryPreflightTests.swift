import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

/// Startup-burst coverage for #21260: five restored agent terminals and a
/// sixth admitted terminal must not open their working directories inside the
/// synchronous main-actor creation call.
@MainActor
@Suite
struct TerminalSurfaceWorkingDirectoryPreflightTests {
    @Test
    func startupBurstDefersNativeCreationUntilWorkingDirectoryOpens() {
        let restored = (0..<5).map { index in
            makeBurstSurface(
                workingDirectory: "/tmp/cmux-burst-restored-\(index)",
                runtimeSpawnPolicy: .pacedSessionRestore
            )
        }
        let admitted = makeBurstSurface(
            workingDirectory: "/tmp/cmux-burst-admitted",
            runtimeSpawnPolicy: .immediate
        )

        for entry in restored {
            entry.surface.createSurface(for: entry.view, source: .scheduledRestore)
        }
        admitted.surface.createSurface(for: admitted.view)

        // Native creation (and Ghostty's main-thread working-directory open)
        // must wait for an off-main open instead of running in this call.
        for entry in restored + [admitted] {
            #expect(entry.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        }
    }

    private func makeBurstSurface(
        workingDirectory: String,
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimRootDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
            installAgentCommandShims: { _, _, _ in nil },
            isExecutableFile: { _ in false }
        )
    ) -> BurstSurface {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let nativeView = FakeTerminalSurfaceNativeView(frame: frame)
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(paneHost)
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: workingDirectory,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(surfaceView: nativeView, paneHost: paneHost),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: RecordingRestoreSpawnScheduler(),
                runtimeFilesystem: runtimeFilesystem,
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
        surface.agentCommandShimInstallCompleted = true
        return BurstSurface(surface: surface, view: nativeView, window: window)
    }
}

@MainActor
private struct BurstSurface {
    let surface: TerminalSurface
    let view: FakeTerminalSurfaceNativeView
    let window: NSWindow
}
