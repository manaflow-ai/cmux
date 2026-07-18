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
}
