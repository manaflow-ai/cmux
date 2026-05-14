import AppKit
import Foundation

/// Stub backend that will bind to `CmuxCore.framework` once the
/// Chromium fork builds. Today every method calls `fatalError` so a
/// misconfigured feature flag fails loudly rather than silently
/// returning empty data.
///
/// Implementation plan: `plans/chromium-engine.md` (P2 milestone).
/// Once `CmuxCore.framework` ships an embedding API, replace the
/// `fatalError`s with `cmux_browser_*` calls and the host `NSView`
/// will be a `CALayerHost`-backed view bound to the GPU helper's
/// `CAContext`.
@MainActor
final class ChromiumBrowserBackend: NSObject, CmuxBrowserBackend {
    nonisolated static func versionString() -> String {
        "Chromium (not yet built) — see plans/chromium-engine.md"
    }

    let placeholder: NSView

    init(configuration: CmuxBrowserConfiguration) {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemRed.cgColor
        self.placeholder = v
        super.init()
        _ = configuration
    }

    var nsView: NSView { placeholder }

    var navigationDelegate: CmuxNavigationDelegate?
    var uiDelegate: CmuxUIDelegate?
    var url: URL? { nil }
    var title: String? { nil }
    var isLoading: Bool { false }
    var estimatedProgress: Double { 0 }
    var canGoBack: Bool { false }
    var canGoForward: Bool { false }
    var customUserAgent: String? { nil }

    private func unavailable() -> Never {
        fatalError(
            "ChromiumBrowserBackend is not yet implemented. " +
            "Disable the cmux.browser.engine.chromium flag or wait for " +
            "the CmuxCore.framework build. See plans/chromium-engine.md."
        )
    }

    func load(_ request: URLRequest) -> CmuxNavigation { unavailable() }
    func loadHTMLString(_ html: String, baseURL: URL?) -> CmuxNavigation { unavailable() }
    func goBack() -> CmuxNavigation? { unavailable() }
    func goForward() -> CmuxNavigation? { unavailable() }
    func reload() -> CmuxNavigation? { unavailable() }
    func stopLoading() {}
    func evaluateJavaScript(_ source: String, completionHandler: @escaping (Any?, Error?) -> Void) {
        completionHandler(nil, CmuxBrowserEngineError.backendUnavailable(.chromium, reason: "Chromium backend not built"))
    }
    func setCustomUserAgent(_ userAgent: String?) {}
    func takeSnapshot(completionHandler: @escaping (CGImage?, Error?) -> Void) {
        completionHandler(nil, CmuxBrowserEngineError.backendUnavailable(.chromium, reason: "Chromium backend not built"))
    }
}
