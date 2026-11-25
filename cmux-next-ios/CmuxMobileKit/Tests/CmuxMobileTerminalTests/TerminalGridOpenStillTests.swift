#if os(iOS)
import CmuxMobileArtifacts
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-22: "the button clicking is not smooth. it's not 120fps."
///
/// The tabs button's tap prepares the terminal page's grid card
/// (`TerminalTabHost.prepareCard`). It rendered the page's still on the main
/// thread inside the tap, so the zoom's first frame waited for it. The still
/// is now composed off the main thread and lands a moment later; the zoom
/// draws the live page meanwhile.
@MainActor
@Suite(.serialized) struct TerminalGridOpenStillTests {
    @Test func openingTheGridComposesTheStillOffTheMainThread() async throws {
        let model = TerminalModel(session: TerminalFrameKeepTests.Silent(), artifactSource: UnavailableArtifactSource(), title: "grid-open")
        let host = TerminalTabHost(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host.controller
        window.makeKeyAndVisible()
        host.controller.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try #require(host.controller.capture(hidingCursor: false) != nil, "the page in a window can be captured")
        #expect(model.snapshot == nil)

        host.prepareCard()
        // Nothing was rendered inside the tap: the still comes from a render off the main thread.
        #expect(model.snapshot == nil, "the grid card's still was rendered on the main thread in the tap")
        let render = try #require(model.cardRender, "the still is rendered off the main thread")
        await render.value
        #expect(model.snapshot != nil, "the rendered still becomes the card's snapshot")
    }

    /// A newer still (another refresh, a main-thread capture) wins over a render still running.
    @Test func aNewerStillWinsOverARenderStillRunning() async throws {
        let model = TerminalModel(session: TerminalFrameKeepTests.Silent(), artifactSource: UnavailableArtifactSource(), title: "grid-open")
        let host = TerminalTabHost(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host.controller
        window.makeKeyAndVisible()
        host.controller.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.prepareCard()
        let render = try #require(model.cardRender)
        model.captureSnapshot()
        let newer = try #require(model.snapshot)
        await render.value
        #expect(model.snapshot === newer, "the older off-main render replaced a newer still")
    }
}
#endif
