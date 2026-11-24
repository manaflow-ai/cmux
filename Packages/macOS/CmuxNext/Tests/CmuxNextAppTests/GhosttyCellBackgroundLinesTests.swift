import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// `appearance.terminalCellBackgrounds` → the Ghostty lines `finalizeConfig` loads
/// (`GhosttyRuntimeSurfacePolicy.cellBackgroundLines`).
@Suite struct GhosttyCellBackgroundLinesTests {
    private func lines(_ mode: TerminalCellBackgrounds, opacity: Double, owner: Bool = false) -> [String] {
        GhosttyRuntimeSurfacePolicy.cellBackgroundLines(mode: mode, configuredOpacity: opacity, ownerPaintsBackground: owner)
    }

    @Test func opaqueLoadsNothing() {
        #expect(lines(.opaque, opacity: 0.7).isEmpty)
        #expect(lines(.opaque, opacity: 1, owner: true).isEmpty)
    }

    @Test func windowTakesTheWindowOpacityOnlyWhenTranslucentOrSeeThrough() {
        #expect(lines(.window, opacity: 0.7) == ["background-cells-opacity = 0.7"])
        #expect(lines(.window, opacity: 1).isEmpty)
        #expect(lines(.window, opacity: 1, owner: true) == ["background-cells-opacity = 1.0"])
    }

    @Test func tintFadesNeutralGreysAtAnyOpacity() {
        #expect(lines(.tint, opacity: 1) == ["background-cells-neutral-fade = 0.5"])
        #expect(lines(.tint, opacity: 0.6) == ["background-cells-neutral-fade = 0.5"])
    }

    @Test func tintWindowLoadsBoth() {
        #expect(lines(.tintWindow, opacity: 0.6) == ["background-cells-opacity = 0.6", "background-cells-neutral-fade = 0.5"])
        #expect(lines(.tintWindow, opacity: 1) == ["background-cells-neutral-fade = 0.5"])
    }
}
