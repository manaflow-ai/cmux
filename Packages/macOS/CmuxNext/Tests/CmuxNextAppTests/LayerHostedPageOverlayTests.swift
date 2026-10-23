import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// A layer-hosted Chromium page (fork API 26) draws in the cmux window's own layer tree; its page
/// window stays over the host only to route the mouse and draws nothing (the fork drops its mask and
/// content while hosted). The overlay panel above page windows and the divider catcher panels exist
/// only because a page window draws over the window's own views: with every page hosted, the window
/// keeps its planes in place (no panel, no child-window reorders) and moves no catcher panel on any
/// frame. The divider hit areas become mouse holes in the hosted page's window instead, which costs
/// no pixels because that window shows none.
@MainActor @Suite(.serialized) struct LayerHostedPageOverlayTests {
    /// The fork's layer hosting call: hosting always granted, context 7.
    static let fork = CEFLayerHosting.Fork(setLayerHosting: { _, enabled in enabled ? 7 : 0 })

    /// The app's window with a page host, a page window over it as the fork places one, and the
    /// host's layer hosting driven by the test (its end-of-turn blocks run when the test says).
    struct Window {
        let window: ShellWindow
        let host: CEFHostView
        let pageWindow: NSWindow
        private let turn: Turn

        final class Turn {
            var blocks: [@MainActor @Sendable () -> Void] = []
            func end() {
                let due = blocks
                blocks = []
                for block in due { block() }
            }
        }

        init() {
            _ = NSApplication.shared
            let turn = Turn()
            self.turn = turn
            let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.blocks.append($0) },
                                          makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) })
            let content = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            window = ShellWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
            host = CEFHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), layerHosting: hosting)
            content.addSubview(host)
            window.orderFront(nil)
            pageWindow = NSWindow(contentRect: window.convertToScreen(host.convert(host.bounds, to: nil)), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            pageWindow.isReleasedWhenClosed = false
            window.addChildWindow(pageWindow, ordered: .above)
            pageWindow.orderFront(nil)
            window.overlayLayer.evaluate()
        }

        /// The fork grants hosting at the end of the turn that created the page window.
        func hostThePage() {
            host.layerHosting.pageWindowCreated(browser: 3, fork: LayerHostedPageOverlayTests.fork)
            turn.end()
        }

        func close() {
            window.removeChildWindow(pageWindow)
            pageWindow.close()
            window.close()
        }
    }

    @Test func aWindowWhosePagesAreAllHostedKeepsItsOverlaysInPlace() throws {
        let page = Window()
        defer { page.close() }
        try #require(page.window.overlayLayer.placement == .overlayWindow, "a page window that draws gets the panel above it")
        page.hostThePage()
        try #require(page.host.isLayerHosted)
        #expect(page.window.overlayLayer.placement == .inWindow, "a hosted page draws under the planes: no panel")
        #expect(page.window.overlayLayer.isOverlayAboveContent)
    }

    @Test func aHostedPageLeavesTheDividerHitAreasToTheWindowWithoutCatcherPanels() throws {
        let page = Window()
        defer { page.close() }
        page.hostThePage()
        // The sidebar's resize band reaches over the page, as a divider's hit area does.
        let band = CGRect(x: 300, y: 0, width: 8, height: 500)
        page.window.overlayLayer.setSidebarResizeBand(band)
        #expect(page.window.overlayLayer.catchers.coveredAreaIDs.isEmpty, "no catcher panel over a hosted page")
        let holes = (page.host.cmuxOcclusionRects() as? [NSValue])?.map(\.rectValue) ?? []
        let local = page.host.convert(band, from: nil)
        #expect(holes.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(local) }, "the band is a mouse hole in the page window: \(holes)")
    }
}
