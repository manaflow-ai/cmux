public import Foundation
public import WebKit
import os

private let hangLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "webkit")

/// A WebKit page whose web content process stopped answering shows "Page unresponsive" with Wait and Exit
/// page, as a Chromium one does (`CEFTab.answerUnresponsivePage`).
///
/// https://github.com/manaflow-ai/cmux/issues/51079: a WebKit tab (open.spotify.com) got stuck and stopped
/// working. Only the Chromium engine reported a hung page, so a WebKit page whose main thread hung showed
/// its last frame with no notice and no way out but closing the tab: a reload goes to the same hung process.
/// WebKit's responsiveness timer reports the hang through its private navigation delegate calls below
/// (`WKNavigationDelegatePrivate`); Exit page ends the process (`_killWebContentProcess`), which shows the
/// sad tab with Reload.
extension WebKitTab: BrowserHangAnswering {
    /// WebKit's responsiveness timer saw no answer from the page's web content process.
    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    public func webViewWebProcessDidBecomeUnresponsive(_ webView: WKWebView) {
        guard !isClosed else { return }
        hangLogger.error("web content process unresponsive tab=\(self.id.rawValue, privacy: .public)")
        apply(.unresponsiveChanged(true))
    }

    /// The page's web content process answers again.
    @objc(_webViewWebProcessDidBecomeResponsive:)
    public func webViewWebProcessDidBecomeResponsive(_ webView: WKWebView) {
        hangRecheck.cancel()
        guard !isClosed, state.isUnresponsive else { return }
        hangLogger.notice("web content process responsive again tab=\(self.id.rawValue, privacy: .public)")
        apply(.unresponsiveChanged(false))
    }

    /// Wait hides the notice and, as Chromium restarts its hang timer, looks again after `hangRecheckDelay`:
    /// WebKit reports a hang only when the process stops answering, never again while it stays hung, so a page
    /// still hung then shows the notice again rather than staying stuck with no way out. Exit page ends the
    /// page's web content process (and any page sharing it, which hangs with it), and its end
    /// (`webContentProcessEnded`) shows the sad tab with Reload.
    public func answerUnresponsivePage(terminate: Bool) {
        guard state.isUnresponsive else { return }
        guard terminate else {
            apply(.unresponsiveChanged(false))
            hangRecheck.schedule(after: hangRecheckDelay) { @MainActor [weak self] in
                guard let self, !self.isClosed, self.state.processExit == nil, !self.webProcessIsResponsive else { return }
                self.apply(.unresponsiveChanged(true))
            }
            return
        }
        hangRecheck.cancel()
        // crash-allow: WebKit SPI, sent only after webView.responds(to:) (no unknown-selector exception).
        let kill = NSSelectorFromString("_killWebContentProcess")
        guard webView.responds(to: kill) else {
            // No way to end the process here: a reload is the best this WebKit offers.
            apply(.unresponsiveChanged(false))
            return reload()
        }
        hangLogger.error("ending unresponsive web content process tab=\(self.id.rawValue, privacy: .public)")
        webView.perform(kill)
    }

    /// Whether the page's web content process answers now (WebKit's `_webProcessIsResponsive`).
    var webProcessIsResponsive: Bool {
        if let webProcessIsResponsiveOverride { return webProcessIsResponsiveOverride() }
        // crash-allow: WebKit SPI, read only after webView.responds(to:) (no unknown-key exception).
        guard webView.responds(to: NSSelectorFromString("_webProcessIsResponsive")) else { return true }
        // crash-allow: KVC read of the WebKit SPI key just checked with responds(to:) (no undefined-key exception).
        return (webView.value(forKey: "_webProcessIsResponsive") as? Bool) ?? true
    }
}
