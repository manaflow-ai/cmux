public import AppKit
public import WebKit

/// Applying a changed render rate to a live page (one path for the agent
/// pane and browser tabs).
public extension WebKitRenderRate {
    /// WebKit reads the rate only when the page's visibility changes, so the
    /// web view is hidden for a moment and shown again. A snapshot of the
    /// page covers it meanwhile. Without a snapshot (or a superview) the
    /// rate waits for the next visibility change instead of blinking the
    /// page. Runs after `previous`, the last re-show, ends.
    ///
    /// - Parameters:
    ///   - snapshot: An image of the page as shown.
    ///   - pause: Waits out one step: 33 ms hidden, then 50 ms covered
    ///     while the shown page paints its first frame (``livePause(_:)``).
    @MainActor
    static func reshow(_ webView: WKWebView, after previous: Task<Void, Never>?,
                       snapshot: @escaping () async -> NSImage?,
                       pause: @escaping (Duration) async -> Void) -> Task<Void, Never> {
        Task { [weak webView] in
            await previous?.value
            guard let webView, let host = webView.superview, let image = await snapshot() else { return }
            let cover = NSImageView(frame: webView.frame)
            cover.image = image
            cover.imageScaling = .scaleAxesIndependently
            cover.autoresizingMask = [.width, .height]
            host.addSubview(cover, positioned: .above, relativeTo: webView)
            let focused = (webView.window?.firstResponder as? NSView)?.isDescendant(of: webView) == true
            webView.isHidden = true
            // Hiding hands keyboard focus to the next key view; take it back
            // unless the user moved it meanwhile.
            let handedTo = webView.window?.firstResponder
            await pause(.milliseconds(33))
            webView.isHidden = false
            if focused, let window = webView.window, window.firstResponder === handedTo {
                window.makeFirstResponder(webView)
            }
            await pause(.milliseconds(50))
            cover.removeFromSuperview()
        }
    }

    /// The real wait of a re-show step.
    nonisolated static func livePause(_ duration: Duration) async {
        // wakeup-allow: one-shot steps of a render-rate change (33 ms hidden, 50 ms covered), injected for tests
        try? await Task.sleep(for: duration)
    }
}
