import CmuxNextDesign
import WebKit

/// The page's WebKit render rate (``PageRenderRate``): one rule and one path with browser tabs
/// (`WebKitRenderRate.set`).
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

    /// Follows the page's ``lowPowerMode`` from now on, and takes its current value at once (a
    /// pooled spare's configuration may be older than the last change). Only a
    /// ``PageRenderRate/display`` page follows it; the others keep the rate they were made with or
    /// that their owner sets. The init calls it.
    func followLowPowerMode() {
        renderRateObservation = nil
        guard engineOptions.renderRate == .display else { return }
        renderRateObservation = lowPowerMode.observe { [weak self] enabled in
            self?.applyRenderRate(lowPowerMode: enabled)
        }
        applyRenderRate(lowPowerMode: lowPowerMode.isEnabled)
    }

    /// Sets the WebKit rate for `lowPowerMode`. WebKit reads the rate only when the page's
    /// visibility changes, so a page on screen is re-shown under a snapshot when its rate changes
    /// there; a hidden page takes it when it is next shown.
    ///
    /// The preference is written while Chromium shows the page too: its WebKit view is hidden then
    /// (no re-show) and shows again on a fallback, at the current rate. A parked spare is not
    /// re-shown: nobody sees it (its parking view is transparent, not hidden), and a claim moves it
    /// out of the parking view, a visibility change WebKit reads the rate on.
    private func applyRenderRate(lowPowerMode: Bool) {
        let fullRate = Self.rendersAtFullRate(engineOptions.renderRate, lowPowerMode: lowPowerMode)
        guard let reshow = WebKitRenderRate.set(fullRate: fullRate, on: webView, replacing: renderRateReshow,
                                                reshowsOnScreen: !isParkedSpare) else { return }
        renderRateReshow = reshow
    }

    /// Stops following Low Power Mode and ends a pending re-show (the page closed).
    func endRenderRate() {
        renderRateObservation = nil
        renderRateReshow?.cancel()
        renderRateReshow = nil
    }
}
