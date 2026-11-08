import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator location presets")
struct SimulatorLocationPresetTests {
    @Test("Pinned serve-sim trails are closed and bounded")
    func closedTrails() throws {
        #expect(SimulatorLocationPreset.allCases.count == 5)
        for preset in SimulatorLocationPreset.allCases {
            let points = preset.closedWaypoints
            #expect(points.count >= 17)
            #expect(points.first == points.last)
            #expect(points.allSatisfy { (-90...90).contains($0.latitude) })
            #expect(points.allSatisfy { (-180...180).contains($0.longitude) })
        }
    }

    @Test("Every transport mode has a positive default speed")
    func transportSpeeds() {
        #expect(SimulatorLocationTransportMode.allCases.allSatisfy {
            $0.metersPerSecond > 0
        })
    }
}
