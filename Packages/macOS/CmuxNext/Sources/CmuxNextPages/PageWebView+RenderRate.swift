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

    /// Sets the WebKit rate for `lowPowerMode`, and re-shows a page on screen under a snapshot
    /// (`WebKitRenderRate.set`), on the claim that WebKit reads the rate when the page's visibility
    /// changes. That claim is not proven: on cmux20 (macOS 27, 120 Hz) a shown Settings page whose
    /// preference went to near60 this way still rendered at 120 fps, while a page made at near60
    /// rendered at 60. Only the rate a page is made with is known to hold, so the pool drops its
    /// spare on a change and makes a new one (``PageHostPool/rateGeneration``) rather than rely on
    /// this; `scripts/cmux-next/bench-page-cadence.py --live` measures both directions.
    ///
    /// The preference is written while Chromium shows the page too: its WebKit view is hidden then
    /// (no re-show) and shows again on a fallback. A parked spare is not re-shown: nobody sees it,
    /// and the pool replaces it.
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
