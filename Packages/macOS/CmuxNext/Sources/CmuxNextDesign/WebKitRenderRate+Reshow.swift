public import AppKit
public import WebKit
import CmuxNextWakeups

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
        let hidden = Duration.milliseconds(33), covered = Duration.milliseconds(50)
        // main-hop-allow: one sequential re-show of a page the owner cancels; each step hides or shows the web view
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
            // wakeup-allow: deadline of a render-rate change's hidden step (33 ms): a step of one sequential task the owner
            // cancels, not a DemandTimer; injected clock
            // timer-class-allow: a step of that cancellable sequence on the owner's injected clock; one per rate change
            let shown: Void? = try? await clock.sleep(for: hidden, tolerance: WakeLeeway.window(delay: hidden).tolerance)
            webView.isHidden = false
            if focused, let window = webView.window, window.firstResponder === handedTo {
                window.makeFirstResponder(webView)
            }
            if shown != nil {
                // wakeup-allow: deadline of a render-rate change's covered step (50 ms), the same sequential task's next step
                // timer-class-allow: the sequence's covered step, the same task and clock
                try? await clock.sleep(for: covered, tolerance: WakeLeeway.window(delay: covered).tolerance)
            }
            cover.removeFromSuperview()
        }
    }
}
