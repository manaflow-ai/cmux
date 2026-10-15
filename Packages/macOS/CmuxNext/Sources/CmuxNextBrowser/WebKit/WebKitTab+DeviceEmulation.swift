import AppKit
import WebKit

/// The daemon's emulation record in WebKit, what Safari's Responsive Design
/// Mode sets: the page's viewport size (the web view's size,
/// `WebKitPageContainer.emulation`; a fit's desktop layout too), the device pixel ratio
/// (`_overrideDeviceScaleFactor` SPI, checked first) and the user agent
/// (`customUserAgent`). WebKit on macOS has nothing for the rest of the
/// record: client hints, touch and `(pointer: coarse)`, the mobile flag,
/// `screen.*` and orientation, and a foldable's hinge.
extension WebKitTab: BrowserEmulating {
    public func applyEmulation(_ emulation: BrowserEmulation?) {
        guard emulation != deviceEmulation else { return }
        if deviceEmulation == nil, emulation != nil { userAgentBeforeEmulation = webView.customUserAgent }
        deviceEmulation = emulation
        let container = contentView as? WebKitPageContainer
        container?.emulation = emulation
        setOverrideDeviceScaleFactor(emulation.map { CGFloat($0.deviceScaleFactor) } ?? 0)
        if let emulation {
            webView.customUserAgent = emulation.userAgent.isEmpty ? userAgentBeforeEmulation : emulation.userAgent
        } else {
            webView.customUserAgent = userAgentBeforeEmulation
            userAgentBeforeEmulation = nil
        }
    }

    /// 0 clears the override (the window's backing scale again).
    private func setOverrideDeviceScaleFactor(_ factor: CGFloat) {
        // crash-allow: WebKit private selector, only checked with responds(to:) (no unknown-selector exception).
        guard webView.responds(to: NSSelectorFromString("_setOverrideDeviceScaleFactor:")) else { return }
        // crash-allow: KVC write of the private setter confirmed above (KVC finds _setOverrideDeviceScaleFactor:).
        webView.setValue(factor, forKey: "overrideDeviceScaleFactor")
    }
}
