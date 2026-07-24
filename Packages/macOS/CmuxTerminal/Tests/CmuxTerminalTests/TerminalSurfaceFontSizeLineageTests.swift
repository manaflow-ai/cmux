import AppKit
import CmuxTerminalCore
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_surface_was_updated")
private func surfaceWasUpdated(_ surface: ghostty_surface_t) -> Bool

@MainActor
@Suite struct TerminalSurfaceFontSizeLineageTests {
    @Test func initialNonExplicitTemplateSeedsFirstRuntimeCreation() {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(19, isExplicitOverride: false)
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

    @Test func oversizedExplicitLineageIsNotPersisted() {
        let surface = makeSurface(configTemplate: CmuxSurfaceConfigTemplate())
        surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 511, isExplicitOverride: true)
        )

        #expect(surface.sessionFontSizeOverrideBasePoints() == nil)
    }

    @Test func maximumExplicitLineageIsPersisted() {
        let surface = makeSurface(configTemplate: CmuxSurfaceConfigTemplate())
        surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 510, isExplicitOverride: true)
        )

        #expect(surface.sessionFontSizeOverrideBasePoints() == 510)
    }

    @Test func dormantSurfaceAdjustsDurableFontSizeAtRuntimeScale() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(6, isExplicitOverride: false)
        let surface = makeSurface(
            configTemplate: template,
            globalFontMagnificationPercent: 200
        )

        #expect(surface.adjustFontSize(byRuntimePoints: -1))

        let lineage = try #require(surface.fontSizeLineageSnapshot())
        #expect(lineage.basePoints == 5.5)
        #expect(lineage.isExplicitOverride)
        #expect(surface.sessionFontSizeOverrideBasePoints() == 5.5)
    }

    @Test func deferredSurfaceUsesConfiguredFallbackAndNativeMinimum() throws {
        let surface = makeSurface(configTemplate: CmuxSurfaceConfigTemplate())

        #expect(surface.adjustFontSize(byRuntimePoints: -20, fallbackRuntimePoints: 12))

        let lineage = try #require(surface.fontSizeLineageSnapshot())
        #expect(lineage.basePoints == TerminalFontSizePolicy.minimumRuntimePoints)
        #expect(lineage.isExplicitOverride)
    }

    @Test func dormantSurfaceSkipsAdjustmentsAtNativeBounds() throws {
        var minimumTemplate = CmuxSurfaceConfigTemplate()
        minimumTemplate.setFontSize(
            TerminalFontSizePolicy.minimumRuntimePoints,
            isExplicitOverride: true
        )
        let minimumSurface = makeSurface(configTemplate: minimumTemplate)
        let minimumLineage = try #require(minimumSurface.fontSizeLineageSnapshot())

        #expect(!minimumSurface.adjustFontSize(byRuntimePoints: -1))
        #expect(minimumSurface.fontSizeLineageSnapshot() == minimumLineage)

        var maximumTemplate = CmuxSurfaceConfigTemplate()
        maximumTemplate.setFontSize(
            TerminalFontSizePolicy.maximumRuntimePoints,
            isExplicitOverride: true
        )
        let maximumSurface = makeSurface(configTemplate: maximumTemplate)
        let maximumLineage = try #require(maximumSurface.fontSizeLineageSnapshot())

        #expect(!maximumSurface.adjustFontSize(byRuntimePoints: 1))
        #expect(maximumSurface.fontSizeLineageSnapshot() == maximumLineage)
    }

    @Test func dormantSurfacePreservesOrderedRunsAtNativeBounds() throws {
        var maximumTemplate = CmuxSurfaceConfigTemplate()
        maximumTemplate.setFontSize(
            TerminalFontSizePolicy.maximumRuntimePoints,
            isExplicitOverride: true
        )
        let maximumSurface = makeSurface(configTemplate: maximumTemplate)

        #expect(
            maximumSurface.adjustFontSize(
                byOrderedRuntimePointDeltas: [1, -1]
            )
        )
        #expect(
            try #require(maximumSurface.fontSizeLineageSnapshot()).basePoints
                == TerminalFontSizePolicy.maximumRuntimePoints - 1
        )

        var minimumTemplate = CmuxSurfaceConfigTemplate()
        minimumTemplate.setFontSize(
            TerminalFontSizePolicy.minimumRuntimePoints,
            isExplicitOverride: true
        )
        let minimumSurface = makeSurface(configTemplate: minimumTemplate)

        #expect(
            minimumSurface.adjustFontSize(
                byOrderedRuntimePointDeltas: [-1, 1]
            )
        )
        #expect(
            try #require(minimumSurface.fontSizeLineageSnapshot()).basePoints
                == TerminalFontSizePolicy.minimumRuntimePoints + 1
        )
    }

    @Test func deferredSurfaceResetClearsOverrideAndFollowsConfiguredSize() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(6, isExplicitOverride: true)
        let surface = makeSurface(
            configTemplate: template,
            globalFontMagnificationPercent: 200
        )

        #expect(surface.resetFontSize(toConfiguredRuntimePoints: 24))

        let lineage = try #require(surface.fontSizeLineageSnapshot())
        #expect(lineage == TerminalFontSizeLineage(basePoints: 12, isExplicitOverride: false))
        #expect(surface.sessionFontSizeOverrideBasePoints() == nil)
        #expect(surface.runtimeCreationConfigTemplate().fontSizeLineage == nil)
    }

    @Test func alreadyConfiguredSurfaceSkipsRedundantReset() {
        let dormantSurface = makeSurface(configTemplate: CmuxSurfaceConfigTemplate())
        #expect(!dormantSurface.resetFontSize(toConfiguredRuntimePoints: 12))

        let registry = FakeSurfaceRegistry()
        let liveSurface = makeSurface(
            configTemplate: CmuxSurfaceConfigTemplate(),
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: liveSurface.id)
        liveSurface.installRuntimeSurfaceForTesting(runtimeSurface)
        defer {
            liveSurface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        #expect(!liveSurface.resetFontSize(toConfiguredRuntimePoints: 12))
    }

    @Test func deferredSurfaceCanZoomAgainAfterReset() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(6, isExplicitOverride: true)
        let surface = makeSurface(configTemplate: template)

        #expect(surface.resetFontSize(toConfiguredRuntimePoints: 12))
        #expect(surface.adjustFontSize(byRuntimePoints: -1, fallbackRuntimePoints: 12))

        let lineage = try #require(surface.fontSizeLineageSnapshot())
        #expect(lineage == TerminalFontSizeLineage(basePoints: 11, isExplicitOverride: true))
        #expect(surface.runtimeCreationConfigTemplate().fontSizeLineage == lineage)
    }

    @Test func deferredSurfaceUsesCurrentConfiguredFallbackAfterReset() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(6, isExplicitOverride: true)
        let surface = makeSurface(configTemplate: template)

        #expect(surface.resetFontSize(toConfiguredRuntimePoints: 12))
        #expect(surface.adjustFontSize(byRuntimePoints: -1, fallbackRuntimePoints: 16))

        #expect(
            try #require(surface.fontSizeLineageSnapshot())
                == TerminalFontSizeLineage(basePoints: 15, isExplicitOverride: true)
        )
    }

    @Test func liveResetDoesNotReloadFullSurfaceConfig() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(6, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        #expect(surface.resetFontSize(toConfiguredRuntimePoints: 12))
        #expect(!surfaceWasUpdated(runtimeSurface))
    }

    @Test func staleRuntimePointerFallsBackToDurableLineageAdjustment() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(12, isExplicitOverride: true)
        let surface = makeSurface(configTemplate: template)
        surface.surface = UnsafeMutableRawPointer(bitPattern: 0x7542)

        #expect(surface.adjustFontSize(byRuntimePoints: -1, fallbackRuntimePoints: 16))
        #expect(surface.surface == nil)
        #expect(
            try #require(surface.fontSizeLineageSnapshot())
                == TerminalFontSizeLineage(basePoints: 11, isExplicitOverride: true)
        )
    }

    @Test func hibernatedNonExplicitLineageUsesCurrentConfiguredFallback() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(19, isExplicitOverride: true)
        let surface = makeSurface(configTemplate: template)
        surface.surface = UnsafeMutableRawPointer(bitPattern: 0x7543)
        surface.surface = nil
        surface.recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(basePoints: 12, isExplicitOverride: false)
        )

        #expect(surface.adjustFontSize(byRuntimePoints: -1, fallbackRuntimePoints: 16))
        #expect(
            try #require(surface.fontSizeLineageSnapshot())
                == TerminalFontSizeLineage(basePoints: 15, isExplicitOverride: true)
        )
    }

    private func makeSurface(
        configTemplate: CmuxSurfaceConfigTemplate,
        globalFontMagnificationPercent: Int = 100,
        engine: FakeTerminalEngine = FakeTerminalEngine(),
        registry: FakeSurfaceRegistry = FakeSurfaceRegistry()
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
                registry: registry,
                engine: engine,
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
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY",
                globalFontMagnificationPercent: { globalFontMagnificationPercent }
            )
        )
    }
}
