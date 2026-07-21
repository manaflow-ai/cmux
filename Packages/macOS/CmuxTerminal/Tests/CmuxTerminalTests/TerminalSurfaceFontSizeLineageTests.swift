import AppKit
import CmuxTerminalCore
import GhosttyKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite struct TerminalSurfaceFontSizeLineageTests {
    @Test func initialNonExplicitTemplateSeedsFirstRuntimeCreation() {
        var template = CmuxSurfaceConfigTemplate()
        template.fontSize = 19
        let surface = makeSurface(configTemplate: template)

        #expect(surface.runtimeSurfaceGeneration == 0)
        #expect(
            surface.runtimeCreationConfigTemplate().fontSizeLineage
                == template.fontSizeLineage
        )
    }

    @Test func nonExplicitObservedLineageDoesNotSeedRuntimeRecreation() {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(19, isExplicitOverride: true)
        let surface = makeSurface(configTemplate: template)
        surface.surface = UnsafeMutableRawPointer(bitPattern: 0x7540)
        surface.surface = nil

        surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 12, isExplicitOverride: false)
        )

        #expect(surface.runtimeSurfaceGeneration == 2)
        #expect(surface.runtimeCreationConfigTemplate().fontSizeLineage == nil)
    }

    private func makeSurface(
        configTemplate: CmuxSurfaceConfigTemplate
    ) -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: configTemplate,
            runtimeSpawnPolicy: .pacedSessionRestore,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
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
                    claudeCommandShimTemporaryDirectory: URL(
                        fileURLWithPath: "/tmp/cmux-terminal-tests",
                        isDirectory: true
                    ),
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
