import CmuxTerminalCore
import Testing

@Suite struct TerminalScrollerStyleTests {
    @Test func onlyAlwaysSelectsTheLegacyGutter() {
        #expect(TerminalScrollerStyle(showScrollBarsPreference: "Always") == .legacy)
    }

    @Test func automaticUsesOverlayEvenWhenAppKitWouldPickLegacy() {
        #expect(TerminalScrollerStyle(showScrollBarsPreference: "Automatic") == .overlay)
        #expect(TerminalScrollerStyle(showScrollBarsPreference: nil) == .overlay)
    }

    @Test func whenScrollingUsesOverlay() {
        #expect(TerminalScrollerStyle(showScrollBarsPreference: "WhenScrolling") == .overlay)
    }
}
