import AppKit
import Foundation

/// Engine-neutral browser view. Hosts the active backend's NSView as a
/// single subview pinned to the bounds. Public API is `WKWebView`-shaped
/// so existing call sites in cmux migrate with minimal churn.
@MainActor
public final class CmuxBrowserView: NSView {
    public let configuration: CmuxBrowserConfiguration

    /// The actual engine doing the work. `internal` so tests in this
    /// package can inspect it directly.
    let backend: any CmuxBrowserBackend

    public var navigationDelegate: (any CmuxNavigationDelegate)? {
        get { backend.navigationDelegate }
        set { backend.navigationDelegate = newValue }
    }

    public var uiDelegate: (any CmuxUIDelegate)? {
        get { backend.uiDelegate }
        set { backend.uiDelegate = newValue }
    }

    public init(frame frameRect: NSRect, configuration: CmuxBrowserConfiguration) {
        self.configuration = configuration
        self.backend = Self.makeBackend(configuration: configuration)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
        installBackend()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported. Use init(frame:configuration:).")
    }

    private static func makeBackend(
        configuration: CmuxBrowserConfiguration
    ) -> any CmuxBrowserBackend {
        switch configuration.engineKind {
        case .webKit:
            return WebKitBrowserBackend(configuration: configuration)
        case .chromium:
            return ChromiumBrowserBackend(configuration: configuration)
        }
    }

    private func installBackend() {
        let inner = backend.nsView
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor),
            inner.topAnchor.constraint(equalTo: topAnchor),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Public API (WKWebView-shaped)

    public var url: URL? { backend.url }
    public var title: String? { backend.title }
    public var isLoading: Bool { backend.isLoading }
    public var estimatedProgress: Double { backend.estimatedProgress }
    public var canGoBack: Bool { backend.canGoBack }
    public var canGoForward: Bool { backend.canGoForward }

    public var customUserAgent: String? {
        get { backend.customUserAgent }
        set { backend.setCustomUserAgent(newValue) }
    }

    /// Page zoom factor. 1.0 = no zoom. Reads and writes go through
    /// the backend. State is mirrored on `state.pageZoom` for Combine
    /// observers.
    public var pageZoom: CGFloat {
        get { backend.pageZoom }
        set { backend.pageZoom = newValue }
    }

    /// Observable mirror of engine load state. Use this to subscribe
    /// via Combine instead of polling the view, e.g.
    /// `view.state.$url.sink { ... }`.
    public var state: CmuxBrowserState { backend.state }

    /// Diagnostic string identifying the active backend ("WebKit 622..."
    /// or "Chromium (not yet built) — ..."). Used in About dialogs and
    /// crash reports.
    public var engineDescription: String {
        switch configuration.engineKind {
        case .webKit: return WebKitBrowserBackend.versionString()
        case .chromium: return ChromiumBrowserBackend.versionString()
        }
    }

    @discardableResult
    public func load(_ request: URLRequest) -> CmuxNavigation {
        backend.load(request)
    }

    @discardableResult
    public func load(_ url: URL) -> CmuxNavigation {
        backend.load(URLRequest(url: url))
    }

    @discardableResult
    public func loadHTMLString(_ html: String, baseURL: URL? = nil) -> CmuxNavigation {
        backend.loadHTMLString(html, baseURL: baseURL)
    }

    @discardableResult public func goBack() -> CmuxNavigation? { backend.goBack() }
    @discardableResult public func goForward() -> CmuxNavigation? { backend.goForward() }
    @discardableResult public func reload() -> CmuxNavigation? { backend.reload() }
    public func stopLoading() { backend.stopLoading() }

    public func evaluateJavaScript(
        _ source: String,
        completionHandler: @escaping (Any?, Error?) -> Void
    ) {
        backend.evaluateJavaScript(source, completionHandler: completionHandler)
    }

    /// Async wrapper around `evaluateJavaScript`. Throws on engine
    /// error; the JS exception value (if any) is rethrown.
    ///
    /// The result is `Any?` (mirroring `WKWebView`'s API). Because `Any`
    /// is not `Sendable`, the continuation hop uses an internal
    /// `@unchecked Sendable` box. The value never crosses an actor in
    /// the meantime — the completion handler runs on the same actor as
    /// `evaluateJavaScript` — so this is safe.
    public func evaluateJavaScript(_ source: String) async throws -> Any? {
        struct ResultBox: @unchecked Sendable { let value: Any? }
        let box: ResultBox = try await withCheckedThrowingContinuation { continuation in
            backend.evaluateJavaScript(source) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ResultBox(value: result))
                }
            }
        }
        return box.value
    }

    public func takeSnapshot(completionHandler: @escaping (CGImage?, Error?) -> Void) {
        backend.takeSnapshot(completionHandler: completionHandler)
    }
}
