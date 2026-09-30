import AppKit
@testable import CmuxNextPalette
import Testing

/// The palette panel is nonactivating: it may take the keys only while the
/// app is active (plans/cmux-next/input-spec.md B9). The test process is
/// never active.
@MainActor
struct PalettePanelKeyTests {
    @Test func thePanelNeverTakesTheKeysWhileTheAppIsInactive() {
        let panel = PalettePanel(size: CGSize(width: 400, height: 300))
        #expect(!panel.canBecomeKey)
    }
}
