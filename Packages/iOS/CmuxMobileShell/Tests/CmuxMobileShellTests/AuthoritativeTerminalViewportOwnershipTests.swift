import CMUXMobileCore
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@Test("direct grids keep producer-native geometry on both terminal screens")
func directGridViewportPolicyUsesProducerGrid() throws {
    for screen in [MobileTerminalRenderGridFrame.Screen.primary, .alternate] {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "surface",
            stateSeq: 1,
            columns: 91,
            rows: 37,
            rowSpans: [],
            activeScreen: screen
        )

        #expect(frame.mobileViewportPolicy == .remoteGrid(columns: 91, rows: 37))
    }
}
