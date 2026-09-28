import CmuxTerminalCore
import Testing

@Suite struct TerminalScrollerStylePolicyTests {
    private typealias Policy = TerminalScrollerStylePolicy

    @Test func onlyAlwaysSelectsTheLegacyGutter() {
        #expect(Policy.style(showScrollBarsPreference: "Always") == .legacy)
    }

    @Test func automaticUsesOverlayEvenWhenAppKitWouldPickLegacy() {
        #expect(Policy.style(showScrollBarsPreference: "Automatic") == .overlay)
        #expect(Policy.style(showScrollBarsPreference: nil) == .overlay)
    }

    @Test func whenScrollingUsesOverlay() {
        #expect(Policy.style(showScrollBarsPreference: "WhenScrolling") == .overlay)
    }
}
