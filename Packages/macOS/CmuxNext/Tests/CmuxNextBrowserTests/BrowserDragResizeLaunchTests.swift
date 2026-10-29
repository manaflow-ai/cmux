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

    /// What Chromium launched with is what the store reports, also after its own read of the file lands.
    @Test func theLaunchValueIsTheStoresValue() throws {
        let file = try Self.file(#"{"browserResize.dragResize": "synced"}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = TunableStore()
        store.register(BrowserResizeTunables.all)
        store.activate(file: file)
        #expect(store.settledOverride(BrowserResizeTunables.dragResize.key) == .choice("synced"))
        #expect(store.override(BrowserResizeTunables.dragResize.key) == .choice("synced"))
    }

    /// Setting the default (a reset) before Chromium starts wins over the file's `synced`, at launch
    /// and once the store's read lands.
    @Test func aResetBeforeTheReadLandsWins() async throws {
        let file = try Self.file(#"{"browserResize.dragResize": "synced"}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = TunableStore()
        store.register(BrowserResizeTunables.all)
        store.activate(file: file)
        store.set(BrowserResizeTunables.dragResize.key, nil)
        #expect(store.settledOverride(BrowserResizeTunables.dragResize.key) == nil)
        try await Task.sleep(for: .milliseconds(300))  // the store's read lands on the main actor
        #expect(store.override(BrowserResizeTunables.dragResize.key) == nil)
    }

    /// Reset all before Chromium starts: the file's `synced` does not come back at launch.
    @Test func aResetAllBeforeTheReadLandsWins() throws {
        let file = try Self.file(#"{"browserResize.dragResize": "synced"}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = TunableStore()
        store.register(BrowserResizeTunables.all)
        store.activate(file: file)
        store.resetAll()
        #expect(store.settledOverride(BrowserResizeTunables.dragResize.key) == nil)
    }

    /// A file from before the three modes: `holdDuringDrag` off is `live`, on is `hold`; the new key wins.
    @Test(arguments: [(#""browserResize.holdDuringDrag": false"#, "live"), (#""browserResize.holdDuringDrag": true"#, "hold"),
                      (#""browserResize.holdDuringDrag": false, "browserResize.dragResize": "synced""#, "synced")])
    func theOldToggleMapsToAMode(values: String, expected: String) throws {
        let file = try Self.file("{\(values)}")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = TunableStore()
        store.register(BrowserResizeTunables.all)
        BrowserResizeTunables.registerRenames(store)
        store.activate(file: file)
        #expect(store.settledOverride(BrowserResizeTunables.dragResize.key) == .choice(expected))
    }

    private static func file(_ values: String) throws -> URL {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "drag-resize-\(UUID().uuidString).json")
        try Data(("{\"version\": 1, \"values\": " + values + "}").utf8).write(to: file)
        return file
    }

    @Test func noFileNoOverride() {
        let store = TunableStore()
        store.register(BrowserResizeTunables.all)
        store.activate(file: nil)
        #expect(store.settledOverride(BrowserResizeTunables.dragResize.key) == nil)
    }
}
