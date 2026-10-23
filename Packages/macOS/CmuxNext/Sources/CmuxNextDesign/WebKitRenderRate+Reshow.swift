public import AppKit
public import WebKit

/// Applying a changed render rate to a live page (one path for the agent
/// pane, browser tabs and cmux pages).
public extension WebKitRenderRate {
    /// Sets `webView` to render at the display's full rate, or near 60 fps,
    /// and applies the change to a page on screen at once: one path for
    /// browser tabs and cmux pages.
    ///
    /// The preference is always written, so a hidden or off-screen view
    /// takes the rate at its next visibility change. A view in a window and
    /// not hidden is re-shown (``reshow(_:replacing:snapshot:clock:)``) when
    /// the rate changed, `reshowsOnScreen` is true and its display renders
    /// the two rates differently (above 60 Hz).
    ///
    /// - Parameters:
    ///   - fullRate: The display's full rate (true) or near 60 fps (false).
    ///   - webView: The page's web view.
    ///   - previous: The owner's running re-show, which a new one replaces.
    ///   - reshowsOnScreen: False for a view on screen that nobody sees (a
    ///     parked spare, whose claim moves it to a new superview: a
    ///     visibility change WebKit reads the rate on).
    ///   - displayFramesPerSecond: The highest rate of a window's display.
    ///   - snapshot: An image of the page as shown; nil takes WebKit's.
    ///   - clock: Times the re-show's steps.
    /// - Returns: The re-show it started, which the owner keeps and cancels
    ///   when it goes away; nil when none started (rate unchanged, no such
    ///   WebKit feature, off screen, or a display at 60 Hz or less).
    @MainActor @discardableResult
    static func set(fullRate: Bool, on webView: WKWebView, replacing previous: Task<Void, Never>?,
                    reshowsOnScreen: Bool = true,
                    displayFramesPerSecond: (NSWindow) -> Int = { $0.screen?.maximumFramesPerSecond ?? 60 },
                    snapshot: (() async -> NSImage?)? = nil,
                    clock: any Clock<Duration> = ContinuousClock()) -> Task<Void, Never>? {
        let preferences = webView.configuration.preferences
        // A WebKit without the feature has no rate to change.
        guard let near60 = preferences.isWebKitFeatureEnabled(near60FPSFeature), near60 == fullRate,
              apply(fullRate: fullRate, to: preferences),
              reshowsOnScreen, let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return nil }
        let display = displayFramesPerSecond(window)
        guard framesPerSecond(lowPowerMode: true, displayMaxFPS: display)
                != framesPerSecond(lowPowerMode: false, displayMaxFPS: display) else { return nil }
        let snapshot = snapshot ?? { [weak webView] in try? await webView?.takeSnapshot(configuration: nil) }
        return reshow(webView, replacing: previous, snapshot: snapshot, clock: clock)
    }

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
