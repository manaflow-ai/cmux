import CoreGraphics
import Foundation
import Testing
import WebKit
@testable import CmuxBrowser

@MainActor
@Suite struct WebKitBrowserPageNativeInputTests {
    private func makePage() -> (WebKitBrowserPage, RecordingNativeInput) {
        let page = WebKitBrowserPage(
            webView: WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: WKWebViewConfiguration())
        )
        let delivery = RecordingNativeInput()
        page.nativeInput = delivery
        return (page, delivery)
    }

    @Test func trustedInputFollowsTheAttachedDelivery() {
        let (page, delivery) = makePage()
        #expect(page.capabilities.contains(.trustedInput))
        page.nativeInput = nil
        #expect(!page.capabilities.contains(.trustedInput))
        withExtendedLifetime(delivery) {}
    }

    @Test func eventsBecomeTheNativeSteps() async throws {
        let (page, delivery) = makePage()
        let at = CGPoint(x: 12, y: 34)

        try await page.dispatchInput(.click(at: at, button: .right, clickCount: 2, modifiers: [.shift, .command]))
        try await page.dispatchInput(.mouseMove(to: at, modifiers: [.option]))
        try await page.dispatchInput(.scroll(at: at, deltaX: 0, deltaY: 40))
        try await page.dispatchInput(.key("Enter", modifiers: [.control]))
        try await page.dispatchInput(.insertText("é"))

        let modifiers: BrowserRawInputModifiers = [.shift, .meta]
        #expect(delivery.delivered == [
            [
                .mouseMoved(.point(at), modifiers: modifiers),
                .mousePressed(.point(at), button: .right, clickCount: 2, modifiers: modifiers),
                .mouseReleased(.point(at), button: .right, clickCount: 2, modifiers: modifiers),
            ],
            [.mouseMoved(.point(at), modifiers: .alt)],
            [.mouseWheel(.point(at), deltaX: 0, deltaY: 40, modifiers: [])],
            [.keyDown("Enter", modifiers: .control), .keyUp("Enter", modifiers: .control)],
            [.insertText("é")],
        ])
        withExtendedLifetime(delivery) {}
    }

    @Test func clickCountsAreClamped() {
        let steps = BrowserPageInputEvent.click(at: .zero, button: .left, clickCount: 1_000, modifiers: []).rawInputSteps
        #expect(steps.count == 3)
        #expect(steps[1] == .mousePressed(.point(.zero), button: .left, clickCount: BrowserRawInputRequest.maximumClickCount, modifiers: []))
    }
}
