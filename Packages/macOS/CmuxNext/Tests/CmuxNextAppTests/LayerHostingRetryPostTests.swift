import AppKit
@testable import CmuxNextBrowser
import Testing

/// A refused layer hosting request (the page window was not attached yet) retries on the fork's next
/// read of the host (`CEFLayerHosting.trackerDidRead`). Page update requests used to make every page
/// post, so that read came at the next layout change; since a page posts only when its geometry
/// changed (PL-motion-cef batch 1), a still page with an armed retry must still post, or it stays on
/// its own window until something moves it (found by the review-2 fix agent, f47dfb4e617).
@MainActor @Suite struct LayerHostingRetryPostTests {
    @Test func aPageWaitingToRetryHostingPostsOnAPageUpdateRequest() throws {
        _ = NSApplication.shared
        var granted = false
        var turn: [@MainActor @Sendable () -> Void] = []
        let fork = CEFLayerHosting.Fork(setLayerHosting: { _, enabled in enabled && granted ? 7 : 0 })
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.append($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = CEFHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), layerHosting: hosting)
        window.contentView = host
        hosting.pageWindowCreated(browser: 3, fork: fork)
        for block in turn { block() }
        turn = []
        try #require(hosting.isRetryArmed, "the first request was refused and waits for the fork's read")
        // The fork read the host once since (its own frame notification), with nothing changed after.
        _ = host.cmuxOcclusionRects()
        granted = true
        let before = CEFHostView.trackerStats.geometryPosts
        // global-notice-allow: CEFHostView observes its window's page update request on the default center (the production path)
        NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window)
        #expect(CEFHostView.trackerStats.geometryPosts - before == 1, "the armed retry gets the fork's read")
    }
}
