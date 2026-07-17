import Testing

@testable import CmuxMobileTerminal

@Suite("Terminal surface tap disposition")
struct GhosttySurfaceTapDispositionTests {
    @Test("only terminal taps claim input focus")
    func inputFocus() {
        #expect(GhosttySurfaceTapDisposition.focusTerminal.shouldFocusTerminal)
        #expect(!GhosttySurfaceTapDisposition.openedArtifact.shouldFocusTerminal)
    }
}
