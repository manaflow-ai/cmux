public import AppKit
public import WebKit

// GRACEFUL-SWAP for a served WebKit view that is not a ``PageWebView``: the agent chat's pane
// (AgentPaneSchemeHandler). A web bundle swap reloaded those with a plain `reload()`, so every open
// chat went blank and drew itself again, twice (the after-run of cmux#50535 on its fleet build:
// 17 transient frames, 9 to 11 blank, in both a focused and an unfocused chat). Leo, 2026-11-22:
// "the agent pane reloaded. i was talking with claude-sr2-coord-old ... no shift, no anything,
// just... ok now it changed". It now swaps the way a page does (PageWebView+GracefulSwap.swift):
// the document hands its state over (`window.cmuxWebSwap.prepare()`), a still of its last frame
// covers the view while the new document restores itself, and the still goes once the restored
// frame is on screen.
@MainActor
public enum WebViewSwap {
    /// The longest the still stays over a view whose document never says it is back.
    static let coverLimit: Duration = .milliseconds(2500)

    /// Reloads `webView` into the web now active, keeping what it shows. A document without the
    /// hand-off (an older bundle) reloads as before; a view out of sight hands over and reloads with no still.
    public static func reload(_ webView: WKWebView) async {
        let prepared = (try? await webView.callAsyncJavaScript(PageWebView.swapPrepareScript, arguments: [:],
                                                                contentWorld: .page)) as? Bool == true
        guard prepared, let host = webView.superview, webView.window != nil, !webView.isHiddenOrHasHiddenAncestor,
              let still = await snapshot(webView)
        else { return webView.reload() }
        // Over the view, not under it: a WebKit view paints its own background between the old
        // document and the new one's first script, which a still under it does not hide.
        let cover = StillCover(frame: webView.frame)
        cover.image = still
        cover.imageScaling = .scaleAxesIndependently
        cover.autoresizingMask = webView.autoresizingMask
        host.addSubview(cover, positioned: .above, relativeTo: webView)
        webView.reload()
        _ = await waitForRestored(webView)
        afterPresentationUpdate(of: webView) { [weak cover] in cover?.removeFromSuperview() }
    }

    private static func snapshot(_ webView: WKWebView) async -> NSImage? {
        await withCheckedContinuation { done in
            webView.takeSnapshot(with: nil) { image, _ in done.resume(returning: image) }
        }
    }

    /// Waits for the new document's `restored()`, at most ``coverLimit``; its probe as JSON.
    private static func waitForRestored(_ webView: WKWebView) async -> String? {
        let deadline = ContinuousClock.now + coverLimit
        while ContinuousClock.now < deadline {
            let answer = try? await webView.callAsyncJavaScript(PageWebView.swapRestoredScript, arguments: [:],
                                                                contentWorld: .page)
            if let text = answer as? String, text != "old", text != "boot" { return text }
            // wakeup-allow: a bounded poll across one reload, never past coverLimit.
            try? await Task.sleep(for: .milliseconds(16))
        }
        return nil
    }

    /// Runs `body` once WebKit put the view's next frame on screen (its private presentation hook), else at once.
    static func afterPresentationUpdate(of webView: WKWebView, _ body: @escaping () -> Void) {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard webView.responds(to: selector) else { return body() }
        typealias Action = @convention(block) () -> Void
        let action: Action = { body() }
        webView.perform(selector, with: action)
    }
}

/// A swap's still: it draws the page's last frame and lets every click through to the page under it,
/// so a press during the swap reaches the new document (which then shows itself at once).
final class StillCover: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
