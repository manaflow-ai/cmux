import AppKit
@testable import CmuxNextBrowser
import Testing

/// Page Info is a nonactivating panel: made key while the app is inactive
/// it took the user's keyboard (plans/cmux-next/input-spec.md B9). The test
/// process is never active.
@MainActor
struct PageInfoPanelKeyTests {
    @Test func theBubbleNeverTakesTheKeysWhileTheAppIsInactive() {
        let panel = PageInfoPanel()
        #expect(!panel.canBecomeKey)
    }
}
