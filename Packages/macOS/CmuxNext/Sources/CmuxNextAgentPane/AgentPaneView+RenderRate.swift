import AppKit
import CmuxNextPages
import WebKit

extension AgentPaneView {
    /// Display information stays native; the page owns adaptive rate policy.
    func framePacingSettings() -> [String: Any] {
        let fps = window?.screen?.maximumFramesPerSecond ?? displayFramesPerSecond()
        return ["adaptive": renderRate == .adaptive && fps > 0,
                "displayInterval": fps > 0 ? 1000 / Double(fps) : 0]
    }

    /// Whether the page renders at the display's full rate. Setting it
    /// changes the live page's preferences and re-shows the page so WebKit
    /// applies them.
    public var rendersAtFullRate: Bool {
        get { webView.configuration.preferences.isWebKitFeatureEnabled(Self.near60FPSFeature) == false }
        set {
            guard newValue != rendersAtFullRate else { return }
            // A WebKit without the feature has no rate to re-apply.
            guard webView.configuration.preferences.setWebKitFeature(Self.near60FPSFeature, enabled: !newValue) else { return }
            reapplyRenderRate()
        }
    }

    /// WebKit reads the rate only when the page's visibility changes: the
    /// shared re-show hides the web view for a moment under a snapshot of
    /// the page. The adaptive rate changes only after a scroll settles, so
    /// the snapshot matches what is on screen.
    private func reapplyRenderRate() {
        rateReapply = WebKitRenderRate.reshow(webView, replacing: rateReapply, snapshot: snapshotPage, clock: clock)
    }
}
