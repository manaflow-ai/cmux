import CmuxNextDesign
import WebKit

/// The page's WebKit render rate (``PageRenderRate``): one rule with browser tabs.
@MainActor
extension PageWebView {
    /// Whether a page with `rate` renders at the display's full rate while Low Power Mode is
    /// `lowPowerMode`.
    static func rendersAtFullRate(_ rate: PageRenderRate, lowPowerMode: Bool) -> Bool {
        switch rate {
        case .display: WebKitRenderRate.prefersFullRate(lowPowerMode: lowPowerMode)
        case .full: true
        case .capped: false
        }
    }

    /// Follows `lowPowerMode` from now on, and takes its current value at once (a pooled spare's
    /// configuration may be older than the last change). Only a ``PageRenderRate/display`` page
    /// follows it; the others keep the rate they were made with or that their owner sets. The
    /// init calls it with the app's observer; tests pass their own.
    func followLowPowerMode(_ lowPowerMode: LowPowerMode = .system) {
        renderRateObservation = nil
        guard engineOptions.renderRate == .display else { return }
        renderRateObservation = lowPowerMode.observe { [weak self] enabled in
            self?.applyRenderRate(lowPowerMode: enabled)
        }
        applyRenderRate(lowPowerMode: lowPowerMode.isEnabled)
    }

    /// Sets the WebKit rate for `lowPowerMode`. WebKit reads the rate only when the page's
    /// visibility changes, so a page on screen is re-shown under a snapshot when its rate changes
    /// there (``WebKitRenderRate/reshow(_:replacing:snapshot:clock:)``, as browser tabs); a hidden
    /// page or a parked spare takes it when it is next shown.
    private func applyRenderRate(lowPowerMode: Bool) {
        let fullRate = Self.rendersAtFullRate(engineOptions.renderRate, lowPowerMode: lowPowerMode)
        let preferences = webView.configuration.preferences
        // A WebKit without the feature has no rate to change; a Chromium page has no WebKit rate.
        guard !showsChromium, let near60 = preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature),
              near60 == fullRate, WebKitRenderRate.apply(fullRate: fullRate, to: preferences),
              let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }
        // A display at 60 Hz or less renders the same either way: no re-show.
        let display = window.screen?.maximumFramesPerSecond ?? 60
        guard WebKitRenderRate.framesPerSecond(lowPowerMode: true, displayMaxFPS: display)
                != WebKitRenderRate.framesPerSecond(lowPowerMode: false, displayMaxFPS: display) else { return }
        renderRateReshow = WebKitRenderRate.reshow(webView, replacing: renderRateReshow, snapshot: { [weak webView] in
            try? await webView?.takeSnapshot(configuration: nil)
        })
    }

    /// Stops following Low Power Mode and ends a pending re-show (the page closed).
    func endRenderRate() {
        renderRateObservation = nil
        renderRateReshow?.cancel()
        renderRateReshow = nil
    }
}
