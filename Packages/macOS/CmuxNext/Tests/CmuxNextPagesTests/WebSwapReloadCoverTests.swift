import Foundation
@testable import CmuxNextPages
import Testing
import WebKit

/// Leo 2026-11-22: "my entire shit like... the agent pane reloaded ... we need to have far more graceful reloads
/// that appear to just be instantly gracefully transitioned." A web update reloads each open page in place
/// (``WebBundleServedViews/reload(_:to:)``); a page whose host keeps it on screen (the agent chat,
/// `AgentPaneView+ReloadCover`) reloads through that host, once, and every other page as before.
@MainActor
@Suite(.serialized)
struct WebSwapReloadCoverTests {
    final class Cover: WebReloadCovering {
        var reloads = 0
        var runsReload = true
        var coversNextReload = true
        func reloadUnderCover(_ reload: @escaping @MainActor () -> Void) {
            reloads += 1
            if runsReload { reload() }
        }
    }

    static func page() -> WKWebView {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 64))
        view.load(URLRequest(url: URL(string: "about:blank") ?? URL(fileURLWithPath: "/")))
        return view
    }

    @Test func aCoveredPageReloadsThroughItsHostOnce() {
        let served = WebBundleServedViews()
        let chat = Self.page(), other = Self.page()
        let cover = Cover()
        served.add(chat)
        served.add(other)
        served.coverReloads(of: chat, with: cover)
        #expect(served.reload([chat, other], to: nil) == 2)
        #expect(cover.reloads == 1)
        #expect(served.reload([other], to: nil) == 1)
        #expect(cover.reloads == 1, "a page without the host's cover never reaches it")
    }

    @Test func aGoneHostLeavesThePlainReload() {
        let served = WebBundleServedViews()
        let chat = Self.page()
        served.add(chat)
        do {
            let cover = Cover()
            served.coverReloads(of: chat, with: cover)
        }
        // The host is gone (weak): the page reloads by itself, with nothing to call.
        #expect(served.reload([chat], to: nil) == 1)
    }

    /// The graceful reload lays its own picture only over a page no host holds: one cover, not two fading apart.
    @Test func theGracefulReloadLeavesAHeldPageToItsHost() {
        let served = WebBundleServedViews()
        let chat = Self.page(), other = Self.page()
        let cover = Cover()
        served.add(chat)
        served.add(other)
        served.coverReloads(of: chat, with: cover)
        #expect(served.coversReload(of: chat))
        #expect(!served.coversReload(of: other))
        cover.coversNextReload = false
        #expect(!served.coversReload(of: chat), "a host that would reload bare leaves the graceful cover")
    }
}
