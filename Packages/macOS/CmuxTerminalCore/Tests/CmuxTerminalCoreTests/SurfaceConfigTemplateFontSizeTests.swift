import Testing
import CmuxTerminalCore
import GhosttyKit

@Suite struct SurfaceConfigTemplateFontSizeTests {
    @Test func freshFontSizeAssignmentClaimsExplicitOwnership() {
        var template = CmuxSurfaceConfigTemplate()

        template.fontSize = 13

        #expect(template.fontSizeLineage == TerminalFontSizeLineage(
            basePoints: 13,
            isExplicitOverride: true
        ))
    }

    @Test func inheritedCConfigFontSizeRemainsNonExplicit() {
        var cConfig = ghostty_surface_config_s()
        cConfig.font_size = 24

        let template = CmuxSurfaceConfigTemplate(
            cConfig: cConfig,
            globalFontMagnificationPercent: 200
        )

        #expect(template.fontSizeLineage == TerminalFontSizeLineage(
            basePoints: 12,
            isExplicitOverride: false
        ))
    }

    @Test func convertsRuntimeFontSizeToBasePoints() {
        let basePoints = CmuxSurfaceConfigTemplate.baseFontSize(fromRuntimePoints: 24, percent: 200)

        #expect(abs(basePoints - 12) < 0.001)
    }

    @Test func convertsBaseFontSizeToRuntimePoints() {
        let runtimePoints = CmuxSurfaceConfigTemplate.runtimeFontSize(fromBasePoints: 12, percent: 200)

        #expect(abs(runtimePoints - 24) < 0.001)
    }

    @Test(arguments: [50, 100, 200])
    func runtimeDefaultFontSizePreservesZeroSentinel(percent: Int) {
        let defaultBasePoints = CmuxSurfaceConfigTemplate().fontSize

        #expect(defaultBasePoints == 0)
        #expect(
            CmuxSurfaceConfigTemplate.runtimeFontSize(
                fromBasePoints: defaultBasePoints,
                percent: percent
            ) == 0
        )
        #expect(
            CmuxSurfaceConfigTemplate.runtimeFontSize(
                fromBasePoints: 0,
                percent: percent
            ) == 0
        )
    }

    @Test(arguments: [50, 100, 200])
    func invalidBaseFontSizeUsesRuntimeDefaultSentinel(percent: Int) {
        let invalidBasePoints: [Float32] = [
            -1,
            .nan,
            .infinity,
            -.infinity,
        ]

        for basePoints in invalidBasePoints {
            #expect(
                CmuxSurfaceConfigTemplate.runtimeFontSize(
                    fromBasePoints: basePoints,
                    percent: percent
                ) == 0
            )
        }
    }

    @Test func inheritedRuntimeFontSizeRoundTripsWithoutCompounding() {
        let basePoints = CmuxSurfaceConfigTemplate.baseFontSize(fromRuntimePoints: 24, percent: 200)
        let runtimePoints = CmuxSurfaceConfigTemplate.runtimeFontSize(fromBasePoints: basePoints, percent: 200)

        #expect(abs(runtimePoints - 24) < 0.001)
    }

    @Test func retainsExplicitFontSizeOwnershipWhileChangingPoints() {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(9, isExplicitOverride: true)

        template.fontSize = 11

        #expect(template.fontSizeLineage == TerminalFontSizeLineage(
            basePoints: 11,
            isExplicitOverride: true
        ))
    }

    @Test func invalidFontSizeClearsLineage() {
        var template = CmuxSurfaceConfigTemplate()
        template.setFontSize(9, isExplicitOverride: true)

        template.fontSize = 0

        #expect(template.fontSizeLineage == nil)
    }

    @Test(arguments: [Float32(511), Float32.greatestFiniteMagnitude])
    func oversizedFontSizeClearsLineage(basePoints: Float32) {
        var propertyTemplate = CmuxSurfaceConfigTemplate()
        propertyTemplate.fontSize = basePoints

        var methodTemplate = CmuxSurfaceConfigTemplate()
        methodTemplate.setFontSize(basePoints, isExplicitOverride: true)

        #expect(propertyTemplate.fontSizeLineage == nil)
        #expect(methodTemplate.fontSizeLineage == nil)
    }

    @Test func maximumPersistableBaseFontSizeIsAccepted() {
        var template = CmuxSurfaceConfigTemplate()

        template.setFontSize(510, isExplicitOverride: true)

        #expect(template.fontSizeLineage == TerminalFontSizeLineage(
            basePoints: 510,
            isExplicitOverride: true
        ))
    }

    @Test func runtimeFontSizeClampsToGhosttyMaximumAtIncreasedMagnification() {
        let runtimePoints = CmuxSurfaceConfigTemplate.runtimeFontSize(
            fromBasePoints: 510,
            percent: 200
        )

        #expect(runtimePoints == 255)
    }

    @Test func maximumRuntimeFontConvertsToMaximumPersistableBaseAtMinimumMagnification() {
        let basePoints = CmuxSurfaceConfigTemplate.baseFontSize(
            fromRuntimePoints: 255,
            percent: 50
        )

        #expect(basePoints == 510)
    }

    @Test func minimumRuntimeFontRoundTripsAtIncreasedMagnification() {
        let basePoints = CmuxSurfaceConfigTemplate.baseFontSize(
            fromRuntimePoints: 1,
            percent: 200
        )
        let restoredRuntimePoints = CmuxSurfaceConfigTemplate.runtimeFontSize(
            fromBasePoints: basePoints,
            percent: 200
        )

        #expect(basePoints == 0.5)
        #expect(restoredRuntimePoints == 1)
    }
}
