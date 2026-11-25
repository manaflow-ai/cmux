@testable import CmuxNextBrowser
import Testing

/// The browser side of cmux#56141's class: the app's own pictures of a Chromium browser tab (leave, hover card, drag,
/// hibernation, a person's screenshot) never ask for a `clip` or a beyond-viewport capture, either of which makes
/// Chromium emulate another viewport and lay the page on screen out again (Leo 2026-11-25: "the pane got resized
/// for some reason visually ... i hoered over the top tabs maybe"). Only the full-page capture an agent asks for
/// (`CEFFullPageCapture`) may.
struct CEFThumbnailParamsTests {
    @Test func noPassiveBrowserPictureAsksForAViewportEmulation() {
        for params in [CEFThumbnail.params, CEFThumbnail.png] {
            #expect(params["clip"] == nil && params["captureBeyondViewport"] == nil, "\(params.keys.sorted())")
        }
    }
}
