import AppKit
import CmuxFoundation
import Foundation
import Testing
import WebKit

@testable import CmuxSidebar

/// Who is allowed to change the sidebar's layout.
///
/// `viewport-fit=cover` is a declaration by *the page* that it will handle the host's chrome insets
/// itself, and honouring it hands the page the full sidebar rect — including the strip under the
/// traffic lights. The bootstrap script that reports it is injected `forMainFrameOnly`, but the
/// message handler is registered on the content controller, which is page-wide: any subframe can
/// call it. A sidebar embedding a third-party iframe is a supported design, so that frame must not
/// be able to push the host page under the window chrome.
@Suite("CustomSidebarWebView viewport message frames", .serialized)
@MainActor
struct CustomSidebarViewportFrameTests {
    /// The wire name the bootstrap script posts to. Spelled out rather than read from the view, so
    /// the test pins the name the page actually sees.
    private static let viewportMessageName = "cmuxSidebarViewport"
    /// A second handler the fixture posts to immediately after the viewport message, used purely as
    /// a delivery signal. Same frame, same channel, posted second, so its arrival means the viewport
    /// message has already been handed to the coordinator.
    private static let echoMessageName = "cmuxTestFrameEcho"

    /// Records the fixture's echo and lets a test await it.
    @MainActor
    private final class FrameEchoSpy: NSObject, WKScriptMessageHandler {
        private var received = false
        private var waiter: CheckedContinuation<Void, Never>?

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            MainActor.assumeIsolated {
                received = true
                waiter?.resume()
                waiter = nil
            }
        }

        func waitForEcho() async {
            if received { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiter = continuation
            }
        }
    }

    private struct Harness {
        let coordinator: CustomSidebarWebView.Coordinator
        let webView: WKWebView
        let container: CustomSidebarWebContainerView
        let echo: FrameEchoSpy
    }

    private func makeHarness() -> Harness {
        let configuration = WKWebViewConfiguration()
        let coordinator = CustomSidebarWebView.Coordinator()
        let echo = FrameEchoSpy()
        configuration.userContentController.add(coordinator, name: Self.viewportMessageName)
        configuration.userContentController.add(echo, name: Self.echoMessageName)
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 480),
            configuration: configuration
        )
        let container = CustomSidebarWebContainerView(webView: webView)
        coordinator.container = container
        coordinator.attach(registry: CustomSidebarFocusHandlerRegistrySpy(), webView: webView)
        return Harness(coordinator: coordinator, webView: webView, container: container, echo: echo)
    }

    /// A page that claims full bleed through the message handler and then signals that it did.
    private static func claimingPage(bodyText: String) -> String {
        """
        <!doctype html><html><body>\(bodyText)<script>
        window.webkit.messageHandlers.\(viewportMessageName).postMessage({ cover: true });
        window.webkit.messageHandlers.\(echoMessageName).postMessage({ from: '\(bodyText)' });
        </script></body></html>
        """
    }

    /// Waits for the fixture's echo, then flushes anything still in flight from the web process.
    ///
    /// The round trip is a synchronous request into the web content process, so it cannot complete
    /// ahead of messages the page posted before it; the yields then let the coordinator's main-actor
    /// hop run. No sleeps: every wait here is on a real signal.
    private func settle(_ harness: Harness) async {
        await harness.echo.waitForEcho()
        _ = try? await harness.webView.evaluateJavaScript("1")
        for _ in 0..<4 { await Task.yield() }
    }

    /// The control: the mechanism under test really does work from the main frame, so a `false`
    /// below is a rejected message rather than a message that never arrived.
    @Test("the main frame's own viewport claim is honoured")
    func mainFrameClaimIsHonoured() async throws {
        let harness = makeHarness()
        #expect(harness.container.isFullBleed == false)

        harness.webView.loadHTMLString(Self.claimingPage(bodyText: "main"), baseURL: nil)
        await settle(harness)

        #expect(harness.container.isFullBleed)
    }

    /// The finding: an embedded frame posts the same message and the host page is laid out full
    /// bleed, sliding the sidebar's first row under the window's traffic lights — a layout the page
    /// itself never asked for.
    @Test("an embedded frame cannot claim full bleed for the page hosting it")
    func subframeClaimIsRejected() async throws {
        let (server, origin) = try LoopbackHTTPServer.started(
            body: Self.claimingPage(bodyText: "sub")
        )
        defer { server.stop() }

        let harness = makeHarness()
        // The host page declares nothing at all, so the only claim in play comes from the frame.
        harness.webView.loadHTMLString(
            "<!doctype html><html><body><iframe src=\"\(origin.absoluteString)\"></iframe></body></html>",
            baseURL: nil
        )
        await settle(harness)

        #expect(harness.container.isFullBleed == false)
    }
}
