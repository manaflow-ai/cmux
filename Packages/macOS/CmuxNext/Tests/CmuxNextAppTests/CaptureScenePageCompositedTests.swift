#if DEBUG
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// `debug.scene.render` refuses a still in which the agent page drew nothing. The agent chat shows
/// in Chromium by default (`agent.chromium`), so a Chromium page image counts as much as a WebKit
/// one; only a snapshot with neither is refused.
struct CaptureScenePageCompositedTests {
    @Test func aChromiumAgentPageCounts() {
        // The answer a Blacksmith capture of scene:composer gave: the scene drew, all in Chromium.
        #expect(CaptureSceneRegistry.pageComposited([
            "method": .string("composited"), "webviews": .number(0), "webviews_composited": .number(0),
            "chromium_pages": .number(1), "chromium_pages_composited": .number(1),
        ]))
    }

    @Test func aWebKitAgentPageCounts() {
        #expect(CaptureSceneRegistry.pageComposited([
            "webviews": .number(1), "webviews_composited": .number(1),
            "chromium_pages": .number(0), "chromium_pages_composited": .number(0),
        ]))
    }

    @Test func noPageImageIsRefused() {
        #expect(!CaptureSceneRegistry.pageComposited([
            "webviews": .number(1), "webviews_composited": .number(0), "webviews_failed": .number(1),
            "chromium_pages": .number(1), "chromium_pages_composited": .number(0), "chromium_pages_failed": .number(1),
        ]))
        #expect(!CaptureSceneRegistry.pageComposited([:]))
    }
}
#endif
