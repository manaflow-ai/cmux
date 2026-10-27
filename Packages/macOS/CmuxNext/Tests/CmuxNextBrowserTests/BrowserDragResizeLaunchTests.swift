import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chromium's launch switches read `browserResize.dragResize` as the override file holds it, also when
/// Chromium starts before the store's own read of the file landed (a restored tab at launch): a "Synced
/// live" override must not start Chromium with AsyncLiveResize on (cmux#25842 review).
@MainActor
struct BrowserDragResizeLaunchTests {
    @Test func theFileValueAppliesWhileTheStoresReadIsPending() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "drag-resize-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"version": 1, "values": {"browserResize.dragResize": "synced"}}"#.utf8).write(to: file)
        let store = TunableStore()
        store.register(BrowserResizeTunables.all)
        store.activate(file: file)
        // The store's own read lands on the main actor later; this turn has not yielded.
        #expect(store.settledOverride(BrowserResizeTunables.dragResize.key) == .choice("synced"))
    }

    @Test func noFileNoOverride() {
        let store = TunableStore()
        store.register(BrowserResizeTunables.all)
        store.activate(file: nil)
        #expect(store.settledOverride(BrowserResizeTunables.dragResize.key) == nil)
    }
}
