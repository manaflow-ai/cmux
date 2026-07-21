import Testing
import CmuxTerminalCore

@Suite struct SurfaceConfigTemplateFontSizeTests {
    @Test func convertsRuntimeFontSizeToBasePoints() {
        let basePoints = CmuxSurfaceConfigTemplate.baseFontSize(fromRuntimePoints: 24, percent: 200)

        #expect(abs(basePoints - 12) < 0.001)
    }

    @Test func convertsBaseFontSizeToRuntimePoints() {
        let runtimePoints = CmuxSurfaceConfigTemplate.runtimeFontSize(fromBasePoints: 12, percent: 200)

        #expect(abs(runtimePoints - 24) < 0.001)
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
