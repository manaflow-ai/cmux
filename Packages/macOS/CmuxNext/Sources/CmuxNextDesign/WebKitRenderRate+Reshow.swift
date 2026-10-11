public import AppKit
public import WebKit

/// Applying a changed render rate to a live page (one path for the agent
/// pane and browser tabs).
public extension WebKitRenderRate {
    /// WebKit reads the rate only when the page's visibility changes, so the
    /// web view is hidden for 33 ms and shown again, and a snapshot of the
    /// page covers it until 50 ms later, while the shown page paints its
    /// first frame. Without a snapshot (or a superview) the rate waits for
    /// the next visibility change instead of blinking the page.
    ///
    /// The owner keeps the returned task and cancels it when it goes away.
    /// A new re-show cancels `previous` and starts when it has ended; a
    /// cancelled re-show shows the page and removes its cover at once.
    ///
    /// - Parameters:
    ///   - snapshot: An image of the page as shown.
    ///   - clock: Times both steps (tests pass a manual clock).
    @MainActor
    static func reshow(_ webView: WKWebView, replacing previous: Task<Void, Never>?,
                       snapshot: @escaping () async -> NSImage?,
                       clock: any Clock<Duration> = ContinuousClock()) -> Task<Void, Never> {
        previous?.cancel()
        return Task { [weak webView] in
            await previous?.value
            guard !Task.isCancelled, let webView, let host = webView.superview,
                  let image = await snapshot(), !Task.isCancelled else { return }
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
            // wakeup-allow: one-shot bounded step of a render-rate change (33 ms hidden) on the owner's injected clock, cancelled with the owner
            let shown: Void? = try? await clock.sleep(for: .milliseconds(33))
            webView.isHidden = false
            if focused, let window = webView.window, window.firstResponder === handedTo {
                window.makeFirstResponder(webView)
            }
            if shown != nil {
                // wakeup-allow: one-shot bounded step of a render-rate change (50 ms covered) on the owner's injected clock, cancelled with the owner
                try? await clock.sleep(for: .milliseconds(50))
            }
            cover.removeFromSuperview()
        }
    }
}
