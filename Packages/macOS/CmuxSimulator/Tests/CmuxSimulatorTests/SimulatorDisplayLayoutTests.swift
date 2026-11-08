import Testing
@testable import CmuxSimulator

@Suite("Simulator display layout")
struct SimulatorDisplayLayoutTests {
    @Test("Aspect fits a portrait device")
    func aspectFitsPortraitDevice() {
        let layout = SimulatorDisplayLayout(
            surface: SimulatorSurfaceGeometry(width: 860, height: 1_000, scale: 2),
            display: SimulatorDisplayMetadata(
                width: 430,
                height: 932,
                orientation: .portrait,
                scale: 3
            )
        )

        #expect(layout.contentRect.width < 860)
        #expect(layout.contentRect.height == 1_000)
    }
}
