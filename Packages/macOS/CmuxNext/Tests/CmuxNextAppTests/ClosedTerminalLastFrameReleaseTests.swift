@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextInput
@testable import CmuxNextTerminal
import CmuxNextWakeups
import IOSurface
import Testing

/// Closing a terminal tab releases the last frame the warm set kept for it (cleanup.md, audit batch 7 A1).
/// A terminal the warm set evicted while its tab stayed in the window keeps one full-resolution drawable
/// (about 20 MB for a full-screen Retina pane) so a switch back shows a picture at once. A closed tab is
/// never shown again, so its frame must go with the tab: before this, `TabContentCache.release` left it to
/// age out under the warm set's bound (up to 24 frames), with its IOSurface and its app-wide
/// `HiddenFrameLRU` entry alive.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct ClosedTerminalLastFrameReleaseTests {
    private func cache() -> TabContentCache {
        let stores = BrowserSharedStores.inMemory()
        return TabContentCache(daemon: DaemonService(),
                               chromium: ChromiumEngineSlot(CEFEngine(layout: nil, stores: stores, signInCallbacks: CEFSignInCallbacks(),
                                                                      input: InputEventTap())),
                               fileInput: NoFileInput(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    /// A 64 x 64 BGRA surface standing in for an evicted terminal's presented drawable.
    private func frame() throws -> TerminalLastFrame {
        let surface = try #require(IOSurface(properties: [
            .width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: 0x4247_5241, // 'BGRA'
        ]))
        return TerminalLastFrame(surface: surface)
    }

    @Test func closingATerminalTabReleasesItsKeptLastFrame() throws {
        let cache = cache()
        let made = try frame()
        cache.lastFrames.evict("closed-tab", atOnce: false, showsOutput: true) { made }
        cache.lastFrames.evict("open-tab", atOnce: false, showsOutput: true) { try? frame() }
        #expect(cache.lastFrames.count == 2)

        cache.release("closed-tab")

        #expect(cache.lastFrames["closed-tab"] == nil, "a closed tab's last frame stays in the store until the warm set's bound drops it")
        #expect(cache.lastFrames["open-tab"] != nil, "another tab's frame must stay")
        #expect(cache.lastFrames.count == 1)
    }

    @Test func aClosedTabsFrameIsFreedOnceNothingElseHoldsIt() throws {
        let cache = cache()
        weak var kept: TerminalLastFrame?
        do {
            let made = try frame()
            kept = made
            cache.lastFrames.evict("closed-tab", atOnce: false, showsOutput: true) { made }
        }
        #expect(kept != nil, "the store keeps an evicted tab's frame")
        let bytes = cache.lastFrames.storedBytes

        cache.release("closed-tab")

        #expect(kept == nil, "the closed tab's frame (and its IOSurface) is still alive after the close")
        #expect(cache.lastFrames.storedBytes == 0, "the store still counts \(bytes) bytes of a closed tab's frame")
    }
}
