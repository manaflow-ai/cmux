import AppKit
import Testing
import WebKit

@testable import CmuxSidebar

@Suite("CustomSidebarWebContainerView chrome insets")
@MainActor
struct CustomSidebarWebInsetsTests {
    private func makeContainer(
        size: CGSize = CGSize(width: 300, height: 800),
        insets: CustomSidebarWebInsets = CustomSidebarWebInsets(top: 46, bottom: 66)
    ) -> CustomSidebarWebContainerView {
        let container = CustomSidebarWebContainerView(webView: WKWebView(frame: .zero))
        container.frame = CGRect(origin: .zero, size: size)
        container.insets = insets
        container.layout()
        return container
    }

    @Test("a page that declares nothing is laid out inside the safe region")
    func defaultsToSafeRegion() {
        let container = makeContainer()
        // Height shrinks by both insets, and the origin lifts by the bottom inset, so the page never
        // renders under the titlebar controls or the footer.
        #expect(container.webView.frame.height == CGFloat(800 - 46 - 66))
        #expect(container.webView.frame.origin.y == CGFloat(66))
        #expect(container.webView.frame.width == CGFloat(300))
    }

    @Test("viewport-fit=cover takes the full sidebar rect")
    func fullBleedFillsBounds() {
        let container = makeContainer()
        container.isFullBleed = true
        container.layout()
        #expect(container.webView.frame == container.bounds)
    }

    // The safe default is the whole point: a naive page must not be able to end up under the chrome
    // just because it never said anything about viewport-fit.
    @Test("a reloaded page starts safe again rather than inheriting the previous page's opt-in")
    func fullBleedResetsAcrossLoads() throws {
        let (server, origin) = try LoopbackHTTPServer.started(body: "<!doctype html><title>fixture</title>")
        defer { server.stop() }
        let container = makeContainer()
        container.isFullBleed = true
        container.layout()
        #expect(container.webView.frame == container.bounds)

        let coordinator = CustomSidebarWebView.Coordinator()
        coordinator.container = container
        coordinator.apply(
            source: .remote(origin),
            focusWorkspace: nil,
            into: container.webView
        )
        container.layout()

        #expect(container.isFullBleed == false)
        #expect(container.webView.frame.height == CGFloat(800 - 46 - 66))
    }

    @Test("changed insets relayout the page")
    func insetChangeRelayouts() {
        let container = makeContainer()
        container.insets = CustomSidebarWebInsets(top: 10, bottom: 20)
        container.layout()
        #expect(container.webView.frame.height == CGFloat(800 - 10 - 20))
        #expect(container.webView.frame.origin.y == CGFloat(20))
    }

    // A sidebar can be dragged narrower than its own chrome; a negative height would be a hard crash
    // in AppKit rather than a cosmetic problem.
    @Test("insets larger than the sidebar clamp to an empty frame instead of going negative")
    func oversizedInsetsClampToZero() {
        let container = makeContainer(size: CGSize(width: 300, height: 40))
        #expect(container.webView.frame.height == CGFloat(0))
    }

    @Test("zero insets are indistinguishable from full bleed")
    func zeroInsetsFillBounds() {
        let container = makeContainer(insets: .zero)
        #expect(container.webView.frame == container.bounds)
    }
}
