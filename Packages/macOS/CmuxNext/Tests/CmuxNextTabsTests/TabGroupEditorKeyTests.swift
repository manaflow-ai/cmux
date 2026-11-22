import AppKit
@testable import CmuxNextTabs
import Testing

/// The group editor is a nonactivating panel: made key while the app is
/// inactive it took the user's keyboard from their frontmost app
/// (plans/cmux-next/input-spec.md B9). The test process is never active.
@MainActor
struct TabGroupEditorKeyTests {
    @Test func theEditorNeverTakesTheKeysWhileTheAppIsInactive() {
        let panel = TabGroupEditorPanel()
        #expect(!panel.canBecomeKey)
    }
}
