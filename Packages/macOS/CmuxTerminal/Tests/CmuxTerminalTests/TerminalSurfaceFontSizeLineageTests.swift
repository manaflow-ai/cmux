import AppKit
import CmuxTerminalCore
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_surface_was_updated")
private func surfaceWasUpdated(_ surface: ghostty_surface_t) -> Bool

@_silgen_name("cmux_test_ghostty_font_state_begin")
private func beginFontState(
    _ surface: ghostty_surface_t,
    _ runtimePoints: Float32,
    _ adjusted: Bool,
    _ configuredRuntimePoints: Float32
)

@_silgen_name("cmux_test_ghostty_font_state_end")
private func endFontState()

@_silgen_name("cmux_test_ghostty_font_binding_result")
private func setFontBindingResult(_ result: Bool)

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

    @Test
    func lateDormantConfigurationFollowerDropsStaleSeedBeforeFirstRuntime() {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(19, isExplicitOverride: false)
        let engine = FakeTerminalEngine()
        let surface = makeSurface(
            configTemplate: template,
            engine: engine
        )

        engine.terminalFontConfigurationGeneration &+= 1

        #expect(surface.runtimeSurfaceGeneration == 0)
        #expect(
            surface.runtimeCreationConfigTemplate().fontSizeLineage
                == nil
        )
    }

    @Test
    func lateDormantConfigurationFollowerExportsRebasedLineage() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(19, isExplicitOverride: false)
        let engine = FakeTerminalEngine()
        let surface = makeSurface(
            configTemplate: template,
            globalFontMagnificationPercent: 200,
            engine: engine
        )

        engine.terminalFontConfigurationRuntimePoints = 24
        engine.terminalFontConfigurationGeneration &+= 1

        let rebasedLineage = try #require(
            surface.fontSizeLineageSnapshot(
                magnificationPercent: 200
            )
        )
        #expect(
            rebasedLineage == TerminalFontSizeLineage(
                basePoints: 12,
                isExplicitOverride: false
            )
        )

        var descendantTemplate = CmuxSurfaceConfigTemplate()
        descendantTemplate.fontSizeLineage = rebasedLineage
        let descendant = makeSurface(
            configTemplate: descendantTemplate,
            globalFontMagnificationPercent: 200,
            engine: engine
        )
        #expect(
            descendant.runtimeCreationConfigTemplate()
                .fontSizeLineage == rebasedLineage
        )
    }

    @Test
    func lateDormantExplicitOverrideRetainsSeedAcrossConfigurationReload() {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(19, isExplicitOverride: true)
        let engine = FakeTerminalEngine()
        let surface = makeSurface(
            configTemplate: template,
            engine: engine
        )

        engine.terminalFontConfigurationGeneration &+= 1

        #expect(surface.runtimeSurfaceGeneration == 0)
        #expect(
            surface.runtimeCreationConfigTemplate().fontSizeLineage
                == template.fontSizeLineage
        )
    }

    @Test func deferredConfigurationCreationDropsNonExplicitSeed() {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(19, isExplicitOverride: false)
        let surface = makeSurface(configTemplate: template)

        surface
            .prepareFontSizeForDeferredConfigurationRuntimeCreation()

        #expect(
            surface.runtimeCreationConfigTemplate().fontSizeLineage
                == nil
        )
    }

    @Test func deferredConfigurationCreationRetainsExplicitSeed() {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(19, isExplicitOverride: true)
        let surface = makeSurface(configTemplate: template)

        surface
            .prepareFontSizeForDeferredConfigurationRuntimeCreation()

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

    @Test func ghosttyFontSizeActionUsesInvariantRoundTripEncoding() throws {
        let points = Float32(10.12345)
        let action =
            ghosttySetFontSizeBindingAction(points)
        let encodedPoints = try #require(
            Float32(
                action.dropFirst(
                    "set_font_size:".count
                )
            )
        )

        #expect(!action.contains(","))
        #expect(
            encodedPoints.bitPattern == points.bitPattern
        )
    }

    @Test func dormantSurfaceAdjustsDurableFontSizeAtRuntimeScale() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(6, isExplicitOverride: false)
        let surface = makeSurface(
            configTemplate: template,
            globalFontMagnificationPercent: 200
        )

        #expect(
            surface.adjustFontSizeOutcome(
                applying: TerminalFontSizeDeltaTransform(
                    orderedRuntimePointDeltas: [-1]
                )
            ) == .applied
        )

        let lineage = try #require(surface.fontSizeLineageSnapshot())
        #expect(lineage.basePoints == 5.5)
        #expect(lineage.isExplicitOverride)
        #expect(surface.sessionFontSizeOverrideBasePoints() == 5.5)
    }

    @Test func zeroNetDormantAdjustmentMakesFollowerExplicit() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(12, isExplicitOverride: false)
        let surface = makeSurface(configTemplate: template)

        #expect(
            surface.adjustFontSizeOutcome(
                applying: TerminalFontSizeDeltaTransform(
                    orderedRuntimePointDeltas: [1, -1]
                )
            ) == .applied
        )

        let lineage = try #require(surface.fontSizeLineageSnapshot())
        #expect(lineage.basePoints == 12)
        #expect(lineage.isExplicitOverride)
        #expect(surface.sessionFontSizeOverrideBasePoints() == 12)
    }

    @Test func zeroNetLiveAdjustmentMakesFollowerExplicit() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(12, isExplicitOverride: false)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        beginFontState(runtimeSurface, 12, false, 12)
        defer {
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        #expect(
            surface.adjustFontSizeOutcome(
                applying: TerminalFontSizeDeltaTransform(
                    orderedRuntimePointDeltas: [1, -1]
                )
            ) == .applied
        )
        #expect(
            GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
                runtimeSurface
            ) == 12
        )
        let lineage = try #require(surface.fontSizeLineageSnapshot())
        #expect(lineage.basePoints == 12)
        #expect(lineage.isExplicitOverride)
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

        #expect(
            minimumSurface.adjustFontSizeOutcome(
                applying: TerminalFontSizeDeltaTransform(
                    orderedRuntimePointDeltas: [-1]
                )
            ) == .alreadySatisfied
        )
        #expect(minimumSurface.fontSizeLineageSnapshot() == minimumLineage)

        var maximumTemplate = CmuxSurfaceConfigTemplate()
        maximumTemplate.setFontSize(
            TerminalFontSizePolicy.maximumRuntimePoints,
            isExplicitOverride: true
        )
        let maximumSurface = makeSurface(configTemplate: maximumTemplate)
        let maximumLineage = try #require(maximumSurface.fontSizeLineageSnapshot())

        #expect(
            maximumSurface.adjustFontSizeOutcome(
                applying: TerminalFontSizeDeltaTransform(
                    orderedRuntimePointDeltas: [1]
                )
            ) == .alreadySatisfied
        )
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
        #expect(
            dormantSurface.resetFontSizeOutcome(
                toConfiguredRuntimePoints: 12
            ) == .alreadySatisfied
        )
        #expect(
            dormantSurface.resetFontSizeOutcome(
                toConfiguredRuntimePoints: .nan
            ) == .failed
        )

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

        #expect(
            liveSurface.resetFontSizeOutcome(
                toConfiguredRuntimePoints: 12
            ) == .alreadySatisfied
        )
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

    @Test
    func configurationReloadReappliesExplicitBaseAtNewMagnification()
        throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(12, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        beginFontState(runtimeSurface, 12, true, 24)
        defer {
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let state =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100
            )
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints: 24,
                magnificationPercent: 200
            ) == .applied
        )

        #expect(
            GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
                runtimeSurface
            ) == 24
        )
        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 200
                )
            ) == TerminalFontSizeLineage(
                basePoints: 12,
                isExplicitOverride: true
            )
        )
    }

    @Test
    func configurationReloadKeepsCapturedLineageAuthoritativeUntilReconciliation()
        throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(13, isExplicitOverride: true)
        let magnification =
            MutableFontMagnificationPercent(100)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            globalFontMagnificationPercentProvider: {
                magnification.value
            },
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        beginFontState(runtimeSurface, 13, true, 26)
        defer {
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let reloadState =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100
            )
        magnification.value = 200

        let inheritedLineage = try #require(
            surface.fontSizeLineageSnapshot()
        )
        #expect(
            inheritedLineage == TerminalFontSizeLineage(
                basePoints: 13,
                isExplicitOverride: true
            )
        )

        var descendantTemplate = CmuxSurfaceConfigTemplate()
        descendantTemplate.fontSizeLineage = inheritedLineage
        let descendant = makeSurface(
            configTemplate: descendantTemplate,
            globalFontMagnificationPercent: 200
        )
        let descendantLineage = try #require(
            descendant.runtimeCreationConfigTemplate()
                .fontSizeLineage
        )
        #expect(
            CmuxSurfaceConfigTemplate.runtimeFontSize(
                fromBasePoints: descendantLineage.basePoints,
                percent: 200
            ) == 26
        )

        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: reloadState,
                configuredRuntimePoints: 26,
                magnificationPercent: 200
            ) == .applied
        )
    }

    @Test
    func configurationReloadFollowerInheritanceUsesTargetConfiguration()
        throws {
        let magnification =
            MutableFontMagnificationPercent(100)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: CmuxSurfaceConfigTemplate(),
            globalFontMagnificationPercentProvider: {
                magnification.value
            },
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        beginFontState(runtimeSurface, 12, false, 28)
        defer {
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let reloadState =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100,
                targetConfiguredRuntimePoints: 28,
                targetMagnificationPercent: 200
            )
        magnification.value = 200

        let inheritedLineage = try #require(
            surface.fontSizeLineageSnapshot()
        )
        #expect(
            inheritedLineage == TerminalFontSizeLineage(
                basePoints: 14,
                isExplicitOverride: false
            )
        )

        var descendantTemplate = CmuxSurfaceConfigTemplate()
        descendantTemplate.fontSizeLineage = inheritedLineage
        let descendant = makeSurface(
            configTemplate: descendantTemplate,
            globalFontMagnificationPercent: 200
        )
        let descendantLineage = try #require(
            descendant.runtimeCreationConfigTemplate()
                .fontSizeLineage
        )
        #expect(
            CmuxSurfaceConfigTemplate.runtimeFontSize(
                fromBasePoints: descendantLineage.basePoints,
                percent: 200
            ) == 28
        )

        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: reloadState,
                configuredRuntimePoints: 28,
                magnificationPercent: 200
            ) == .applied
        )
    }

    @Test
    func configurationReloadPreservesExplicitBaseAcrossRuntimeClamp()
        throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(200, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        beginFontState(runtimeSurface, 200, true, 24)
        defer {
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let magnifiedState =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100
            )
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: magnifiedState,
                configuredRuntimePoints: 24,
                magnificationPercent: 200
            ) == .applied
        )
        #expect(
            GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
                runtimeSurface
            ) == TerminalFontSizePolicy.maximumRuntimePoints
        )
        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 200
                )
            ) == TerminalFontSizeLineage(
                basePoints: 200,
                isExplicitOverride: true
            )
        )

        let restoredState =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 200
            )
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: restoredState,
                configuredRuntimePoints: 12,
                magnificationPercent: 100
            ) == .applied
        )
        #expect(
            GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
                runtimeSurface
            ) == 200
        )
        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 100
                )
            ) == TerminalFontSizeLineage(
                basePoints: 200,
                isExplicitOverride: true
            )
        )
    }

    @Test
    func configurationReloadRebasesFollowerWhilePreservingMobileFit()
        throws {
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: CmuxSurfaceConfigTemplate(),
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.mobileViewportFontFitState =
            MobileViewportFontFitState(
                baseRuntimePointSize: 12,
                fittedRuntimePointSize: 8
            )
        beginFontState(runtimeSurface, 8, true, 24)
        defer {
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let state =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100
            )
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints: 24,
                magnificationPercent: 200
            ) == .alreadySatisfied
        )

        #expect(
            surface.mobileViewportFontFitState
                == MobileViewportFontFitState(
                    baseRuntimePointSize: 24,
                    fittedRuntimePointSize: 8
                )
        )
        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 200
                )
            ) == TerminalFontSizeLineage(
                basePoints: 12,
                isExplicitOverride: false
            )
        )
    }

    @Test
    func mobileViewportFitOwnershipSurvivesDurableEquality() {
        var state = MobileViewportFontFitState(
            baseRuntimePointSize: 13,
            fittedRuntimePointSize: 8
        )

        state.updateDurableBase(to: 7)
        #expect(
            state == MobileViewportFontFitState(
                baseRuntimePointSize: 7,
                fittedRuntimePointSize: 7,
                viewportFitCeilingRuntimePointSize: 8
            )
        )

        state.updateDurableBase(to: 8)
        #expect(
            state == MobileViewportFontFitState(
                baseRuntimePointSize: 8,
                fittedRuntimePointSize: 8
            )
        )

        state.updateDurableBase(to: 9)
        #expect(
            state == MobileViewportFontFitState(
                baseRuntimePointSize: 9,
                fittedRuntimePointSize: 8
            )
        )
    }

    @Test
    func configurationReloadRebasesNeverRealizedFollower() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(12, isExplicitOverride: false)
        let surface = makeSurface(configTemplate: template)

        let state =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100
            )
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints: 20,
                magnificationPercent: 200
            ) == .alreadySatisfied
        )

        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 200
                )
            ) == TerminalFontSizeLineage(
                basePoints: 10,
                isExplicitOverride: false
            )
        )
        #expect(
            surface.runtimeCreationConfigTemplate().fontSizeLineage == nil
        )
    }

    @Test
    func configurationReloadMergesTerminalLocalFontInput() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(13, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        beginFontState(runtimeSurface, 13, true, 26)
        defer {
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let state =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100,
                targetConfiguredRuntimePoints: 26,
                targetMagnificationPercent: 200
            )
        #expect(
            surface.performExplicitInputBindingAction(
                "increase_font_size:1"
            )
        )
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints: 26,
                magnificationPercent: 200
            ) == .applied
        )

        #expect(
            GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
                runtimeSurface
            ) == 27
        )
        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 200
                )
            ) == TerminalFontSizeLineage(
                basePoints: 13.5,
                isExplicitOverride: true
            )
        )
    }

    @Test
    func configurationReloadPreservesAbsoluteTerminalLocalFontInput() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(13, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        beginFontState(runtimeSurface, 13, true, 26)
        defer {
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let state =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100,
                targetConfiguredRuntimePoints: 26,
                targetMagnificationPercent: 200
            )
        #expect(
            surface.performExplicitInputBindingAction(
                "set_font_size:20"
            )
        )
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints: 26,
                magnificationPercent: 200
            ) == .alreadySatisfied
        )

        #expect(
            GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
                runtimeSurface
            ) == 20
        )
        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 200
                )
            ) == TerminalFontSizeLineage(
                basePoints: 10,
                isExplicitOverride: true
            )
        )
    }

    @Test
    func configurationReloadPreservesRepeatedAbsoluteTerminalLocalFontInput()
        throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(20, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        beginFontState(runtimeSurface, 20, true, 26)
        defer {
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let state =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100,
                targetConfiguredRuntimePoints: 26,
                targetMagnificationPercent: 200
            )
        #expect(
            surface.performExplicitInputBindingAction(
                "set_font_size:20"
            )
        )
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints: 26,
                magnificationPercent: 200
            ) == .alreadySatisfied
        )

        #expect(
            GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
                runtimeSurface
            ) == 20
        )
        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 200
                )
            ) == TerminalFontSizeLineage(
                basePoints: 10,
                isExplicitOverride: true
            )
        )
    }

    @Test
    func configurationReloadAppliesRelativeInputAfterAbsoluteInput() {
        var state = TerminalFontSizeConfigurationReloadState(
            transactionId: UUID(),
            surfaceId: UUID(),
            lineage: TerminalFontSizeLineage(
                basePoints: 13,
                isExplicitOverride: true
            ),
            inheritanceLineage: nil,
            followsConfiguredFontSize: false,
            targetConfiguredRuntimePoints: 26,
            targetMagnificationPercent: 200
        )

        state.recordAbsoluteFontInput(
            currentRuntimePoints: 20,
            currentIsAdjusted: true
        )
        state.recordRelativeFontInput(
            previousRuntimePoints: 20,
            currentRuntimePoints: 21,
            previousIsAdjusted: true,
            currentIsAdjusted: true
        )

        #expect(
            state.resolvedTarget(
                configuredRuntimePoints: 26,
                magnificationPercent: 200
            ).durableRuntimePoints == 21
        )
    }

    @Test
    func configurationReloadAppliesRelativeInputAfterResetInput() {
        var state = TerminalFontSizeConfigurationReloadState(
            transactionId: UUID(),
            surfaceId: UUID(),
            lineage: TerminalFontSizeLineage(
                basePoints: 13,
                isExplicitOverride: true
            ),
            inheritanceLineage: nil,
            followsConfiguredFontSize: false,
            targetConfiguredRuntimePoints: 26,
            targetMagnificationPercent: 200
        )

        state.recordResetFontInput()
        state.recordRelativeFontInput(
            previousRuntimePoints: 13,
            currentRuntimePoints: 14,
            previousIsAdjusted: false,
            currentIsAdjusted: true
        )

        #expect(
            state.resolvedTarget(
                configuredRuntimePoints: 26,
                magnificationPercent: 200
            ).durableRuntimePoints == 27
        )
    }

    @Test
    func configurationReloadReanchorsRelativeInputAfterNativeReset() {
        var state = TerminalFontSizeConfigurationReloadState(
            transactionId: UUID(),
            surfaceId: UUID(),
            lineage: TerminalFontSizeLineage(
                basePoints: 13,
                isExplicitOverride: false
            ),
            inheritanceLineage: nil,
            followsConfiguredFontSize: true,
            targetConfiguredRuntimePoints: 26,
            targetMagnificationPercent: 200
        )

        state.recordRelativeFontInput(
            previousRuntimePoints: 13,
            currentRuntimePoints: 14,
            previousIsAdjusted: false,
            currentIsAdjusted: true
        )
        state.recordRelativeFontInput(
            previousRuntimePoints: 26,
            currentRuntimePoints: 27,
            previousIsAdjusted: false,
            currentIsAdjusted: true
        )

        #expect(
            state.resolvedTarget(
                configuredRuntimePoints: 26,
                magnificationPercent: 200
            ).durableRuntimePoints == 27
        )
    }

    @Test
    func configurationReloadKeepsClampedIncreaseExplicit() throws {
        try assertConfigurationReloadKeepsClampedInputExplicit(
            startingRuntimePoints:
                TerminalFontSizePolicy.maximumRuntimePoints,
            action: "increase_font_size:1"
        )
    }

    @Test
    func configurationReloadKeepsClampedDecreaseExplicit() throws {
        try assertConfigurationReloadKeepsClampedInputExplicit(
            startingRuntimePoints:
                TerminalFontSizePolicy.minimumRuntimePoints,
            action: "decrease_font_size:1"
        )
    }

    private func assertConfigurationReloadKeepsClampedInputExplicit(
        startingRuntimePoints: Float32,
        action: String
    ) throws {
        let targetConfiguredRuntimePoints: Float32 = 24
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(
            startingRuntimePoints,
            isExplicitOverride: false
        )
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        beginFontState(
            runtimeSurface,
            startingRuntimePoints,
            false,
            targetConfiguredRuntimePoints
        )
        defer {
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let state =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100,
                targetConfiguredRuntimePoints:
                    targetConfiguredRuntimePoints,
                targetMagnificationPercent: 100
            )
        #expect(
            surface.performExplicitInputBindingAction(action)
        )
        #expect(
            GhosttySurfaceRuntimeProbe
                .currentSurfaceFontSizePoints(runtimeSurface)
                == startingRuntimePoints,
            "The native bound must clamp the observed point delta to zero"
        )
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints:
                    targetConfiguredRuntimePoints,
                magnificationPercent: 100
            ) == .applied
        )

        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 100
                )
            ) == TerminalFontSizeLineage(
                basePoints: targetConfiguredRuntimePoints,
                isExplicitOverride: true
            )
        )
    }

    @Test
    func failedConfigurationReloadReconciliationRemainsRetryable()
        throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(13, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        beginFontState(runtimeSurface, 13, true, 26)
        defer {
            setFontBindingResult(true)
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let state =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100,
                targetConfiguredRuntimePoints: 26,
                targetMagnificationPercent: 200
            )
        setFontBindingResult(false)
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints: 26,
                magnificationPercent: 200
            ) == .failed
        )
        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 200
                )
            ) == TerminalFontSizeLineage(
                basePoints: 13,
                isExplicitOverride: true
            ),
            "A failed native mutation must retain the captured authority"
        )

        setFontBindingResult(true)
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints: 26,
                magnificationPercent: 200
            ) == .applied
        )
        #expect(
            GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
                runtimeSurface
            ) == 26
        )
    }

    @Test
    func abandonedConfigurationReloadPinsObservedFallback() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(13, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        beginFontState(runtimeSurface, 13, true, 26)
        defer {
            setFontBindingResult(true)
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let state =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100,
                targetConfiguredRuntimePoints: 26,
                targetMagnificationPercent: 200
            )
        setFontBindingResult(false)
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints: 26,
                magnificationPercent: 200
            ) == .failed
        )
        surface
            .abandonFontSizeConfigurationReloadReconciliation(
                from: state,
                magnificationPercent: 200
            )

        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 200
                )
            ) == TerminalFontSizeLineage(
                basePoints: 6.5,
                isExplicitOverride: true
            )
        )
    }

    @Test
    func abandonedConfigurationReloadPreservesDurableMobileFitBase() {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(13, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.mobileViewportFontFitState =
            MobileViewportFontFitState(
                baseRuntimePointSize: 13,
                fittedRuntimePointSize: 8
            )
        beginFontState(runtimeSurface, 8, true, 13)
        defer {
            setFontBindingResult(true)
            endFontState()
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        let state =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100,
                targetConfiguredRuntimePoints: 26,
                targetMagnificationPercent: 200
            )
        beginFontState(runtimeSurface, 8, false, 26)
        setFontBindingResult(false)
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints: 26,
                magnificationPercent: 200
            ) == .failed
        )

        surface
            .abandonFontSizeConfigurationReloadReconciliation(
                from: state,
                magnificationPercent: 200
            )

        #expect(
            surface.mobileViewportFontFitState
                == MobileViewportFontFitState(
                    baseRuntimePointSize: 26,
                    fittedRuntimePointSize: 8
                )
        )
        #expect(
            surface.lastKnownFontSizeLineage
                == TerminalFontSizeLineage(
                    basePoints: 13,
                    isExplicitOverride: true
                )
        )
        #expect(!surface.followsConfiguredFontSize)
    }

    @Test
    func neverRealizedFollowerUsesTargetReloadInheritance() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(12, isExplicitOverride: false)
        let surface = makeSurface(configTemplate: template)

        let state =
            surface.captureFontSizeConfigurationReloadState(
                magnificationPercent: 100,
                targetConfiguredRuntimePoints: 28,
                targetMagnificationPercent: 200
            )
        #expect(
            try #require(
                surface.fontSizeLineageSnapshot(
                    magnificationPercent: 200
                )
            ) == TerminalFontSizeLineage(
                basePoints: 14,
                isExplicitOverride: false
            )
        )
        #expect(
            surface.reconcileFontSizeAfterConfigurationReload(
                from: state,
                configuredRuntimePoints: 28,
                magnificationPercent: 200
            ) == .alreadySatisfied
        )
    }

    @Test func liveAdjustmentUsesDurableMobileFitBase() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(13, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        var acceptedInputCount = 0
        surface.onExplicitInput = { acceptedInputCount += 1 }
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.mobileViewportFontFitState = MobileViewportFontFitState(
            baseRuntimePointSize: 13,
            fittedRuntimePointSize: 8
        )
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        #expect(surface.adjustFontSize(byRuntimePoints: -1))
        #expect(acceptedInputCount == 0)
        #expect(
            try #require(surface.fontSizeLineageSnapshot())
                == TerminalFontSizeLineage(
                    basePoints: 12,
                    isExplicitOverride: true
                )
        )
        #expect(
            surface.mobileViewportFontFitState
                == MobileViewportFontFitState(
                    baseRuntimePointSize: 12,
                    fittedRuntimePointSize: 8
                )
        )
    }

    @Test func liveAdjustmentKeepsMobileFitAtOrBelowDurableBase() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(13, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        var acceptedInputCount = 0
        surface.onExplicitInput = { acceptedInputCount += 1 }
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.mobileViewportFontFitState = MobileViewportFontFitState(
            baseRuntimePointSize: 13,
            fittedRuntimePointSize: 8
        )
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        #expect(surface.adjustFontSize(byRuntimePoints: -6))
        #expect(acceptedInputCount == 0)
        #expect(
            try #require(surface.fontSizeLineageSnapshot())
                == TerminalFontSizeLineage(
                    basePoints: 7,
                    isExplicitOverride: true
                )
        )
        #expect(
            surface.mobileViewportFontFitState
                == MobileViewportFontFitState(
                    baseRuntimePointSize: 7,
                    fittedRuntimePointSize: 7,
                    viewportFitCeilingRuntimePointSize: 8
                )
        )
    }

    @Test func liveClampedMobileAdjustmentAcceptsExplicitOwnership() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(
            TerminalFontSizePolicy.minimumRuntimePoints,
            isExplicitOverride: false
        )
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        var acceptedInputCount = 0
        surface.onExplicitInput = { acceptedInputCount += 1 }
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.mobileViewportFontFitState = MobileViewportFontFitState(
            baseRuntimePointSize: TerminalFontSizePolicy.minimumRuntimePoints,
            fittedRuntimePointSize: TerminalFontSizePolicy.minimumRuntimePoints
        )
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        #expect(surface.adjustFontSize(byRuntimePoints: -1))
        #expect(acceptedInputCount == 0)
        #expect(
            try #require(surface.fontSizeLineageSnapshot())
                == TerminalFontSizeLineage(
                    basePoints: TerminalFontSizePolicy.minimumRuntimePoints,
                    isExplicitOverride: true
                )
        )
    }

    @Test func liveResetPreservesTemporaryMobileFit() throws {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(13, isExplicitOverride: true)
        let registry = FakeSurfaceRegistry()
        let surface = makeSurface(
            configTemplate: template,
            registry: registry
        )
        var acceptedInputCount = 0
        surface.onExplicitInput = { acceptedInputCount += 1 }
        let runtimeSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        registry.registerRuntimeSurface(
            runtimeSurface,
            ownerId: surface.id
        )
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        surface.mobileViewportFontFitState = MobileViewportFontFitState(
            baseRuntimePointSize: 13,
            fittedRuntimePointSize: 8
        )
        defer {
            surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        #expect(surface.resetFontSize(toConfiguredRuntimePoints: 14))
        #expect(acceptedInputCount == 0)
        #expect(
            try #require(surface.fontSizeLineageSnapshot())
                == TerminalFontSizeLineage(
                    basePoints: 14,
                    isExplicitOverride: false
                )
        )
        #expect(surface.sessionFontSizeOverrideBasePoints() == nil)
        #expect(
            surface.mobileViewportFontFitState
                == MobileViewportFontFitState(
                    baseRuntimePointSize: 14,
                    fittedRuntimePointSize: 8
                )
        )
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

    @Test func retiringTransferTokenClearsSourceAndDescendant() {
        let token = UUID()
        defer {
            retireTerminalFontSizeChangeReconciliationToken(
                token
            )
        }
        let source = makeSurface(configTemplate: CmuxSurfaceConfigTemplate())
        source.markFontSizeChangeReconciledForTransfer(token: token)
        let descendant = makeSurface(
            configTemplate: source.runtimeCreationConfigTemplate()
        )

        #expect(source.hasAppliedFontSizeChange(token: token))
        #expect(descendant.hasAppliedFontSizeChange(token: token))

        retireTerminalFontSizeChangeReconciliationToken(
            token
        )

        #expect(!source.hasAppliedFontSizeChange(token: token))
        #expect(!descendant.hasAppliedFontSizeChange(token: token))
        #expect(
            descendant.runtimeCreationConfigTemplate()
                .fontSizeChangeTokens.isEmpty
        )
        #expect(
            TerminalSurface
                .debugLastTransferTokenRetirementSurfaceVisitCount == 0,
            "Retiring transient provenance must use lazy invalidation"
        )
    }

    @Test func exportingTransferTokensPrunesRetiredStorage() {
        let surface = makeSurface(
            configTemplate: CmuxSurfaceConfigTemplate()
        )
        for _ in 0..<100 {
            let token = UUID()
            surface.markFontSizeChangeReconciledForTransfer(
                token: token
            )
            retireTerminalFontSizeChangeReconciliationToken(
                token
            )
        }

        #expect(surface.fontSizeChangeTokensForInheritance().isEmpty)
        #expect(
            surface.debugTransferReconciliationTokenStorageCount == 0,
            "Lazy invalidation must remove retired entries from surface storage"
        )
    }

    private func makeSurface(
        configTemplate: CmuxSurfaceConfigTemplate,
        globalFontMagnificationPercent: Int = 100,
        globalFontMagnificationPercentProvider:
            (@Sendable () -> Int)? = nil,
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
                    agentCommandShimTemporaryDirectory: URL(
                        fileURLWithPath: "/tmp/cmux-terminal-tests",
                        isDirectory: true
                    ),
                    installAgentCommandShims: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY",
                globalFontMagnificationPercent:
                    globalFontMagnificationPercentProvider
                    ?? { globalFontMagnificationPercent }
            )
        )
    }
}
