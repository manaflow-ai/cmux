#if os(iOS)
import Observation
import SwiftUI
import UIKit
import WebKit
import CmuxMobileBrowserStream
import CmuxTabsKit

/// One browser tab's `WKWebView` and the state the tab toolbar shows. The
/// web view lives as long as the tab, so switching tabs or zooming to the
/// grid never reloads the page. (A streamed Mac browser replaces this later.)
@MainActor
@Observable
public final class BrowserTabModel: BrowserTabState {
    public private(set) var url: URL?
    public private(set) var title: String = ""
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var isLoading = false
    public private(set) var progress: Double = 1
    public private(set) var snapshot: UIImage?
    /// Why the phone's page shows no page (a tab opened on the iPhone from the Mac):
    /// an address only the Mac can open, or a host this iPhone could not reach.
    public private(set) var problem: Problem?
    @ObservationIgnored public let webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// The page's address changed (a tab opened on the iPhone remembers where it is).
    @ObservationIgnored var urlChanged: (@MainActor (URL) -> Void)?
    /// Opened on the iPhone from a Mac's page: the Mac's own addresses (`localhost`)
    /// are not loaded here, and an unreachable host says so.
    @ObservationIgnored private var guardian: MacAddressGuard?

    public struct Problem: Equatable {
        public var url: URL
        /// Only the Mac can open it (its `localhost`, a `file:` page); else the phone could not reach it.
        public var isMacOnly: Bool
        /// A private, LAN or tailnet host (the Mac may reach it when the phone can't).
        public var isPrivateNetwork: Bool
        public var message: String
    }

    public init(url: URL?, guardsMacAddresses: Bool = false) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        self.url = url
        if guardsMacAddresses {
            let guardian = MacAddressGuard(model: self)
            self.guardian = guardian
            webView.navigationDelegate = guardian
        }
        observe()
        if let url { load(url) }
    }

    /// Loads an address; on a page opened from the Mac, one only the Mac can open
    /// shows why instead.
    public func load(_ target: URL) {
        if guardian != nil, PhoneReach(target) == .macOnly {
            refuse(target)
            return
        }
        problem = nil
        // The address bar shows where the page is going at once (as Safari's does).
        url = target
        webView.load(URLRequest(url: target))
    }

    func refuse(_ target: URL) {
        url = target
        problem = Problem(url: target, isMacOnly: true, isPrivateNetwork: false, message: "")
    }

    func unreachable(_ target: URL, _ error: any Error) {
        problem = Problem(url: target, isMacOnly: false, isPrivateNetwork: PhoneReach(target) == .privateNetwork,
                          message: error.localizedDescription)
    }

    public func clearProblem() { problem = nil }

    /// Stops loading and media behind the mirror (the page stays for the next visit).
    func pause() {
        webView.stopLoading()
        webView.pauseAllMediaPlayback()
    }

    private func observe() {
        func watch<V: Sendable>(_ path: KeyPath<WKWebView, V>, _ apply: @escaping @MainActor (BrowserTabModel, V) -> Void) {
            observations.append(webView.observe(path, options: [.initial, .new]) { [weak self] web, _ in
                let value = web[keyPath: path]
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self, value)
                }
            })
        }
        watch(\.url) { model, value in
            guard let value else { return }
            model.url = value
            model.urlChanged?(value)
        }
        watch(\.title) { model, value in model.title = value ?? "" }
        watch(\.canGoBack) { model, value in model.canGoBack = value }
        watch(\.canGoForward) { model, value in model.canGoForward = value }
        watch(\.isLoading) { model, value in model.isLoading = value }
        watch(\.estimatedProgress) { model, value in model.progress = value }
    }

    public var host: String { url.map(TabsKitAddress.displayLabel(for:)) ?? "" }

    public func goBack() { _ = webView.goBack() }
    public func goForward() { _ = webView.goForward() }
    public func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
        } else if let problem {
            // Try Again: the failed address, not the last page that loaded.
            load(problem.url)
        } else {
            _ = webView.reload()
        }
    }

    /// A URL, a host and port, a bare host, or a search.
    public func navigate(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = Self.url(for: trimmed) else { return }
        load(target)
    }

    nonisolated static func url(for text: String) -> URL? {
        if text.isEmpty { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) { return url }
        // `localhost:3000`, `mac.local:8080/x`: a host and port (URL(string:) reads the host as a scheme).
        if !text.contains(" "), text.wholeMatch(of: /[A-Za-z0-9.-]+:[0-9]{1,5}(\/.*)?/) != nil {
            return URL(string: "http://\(text)")
        }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://\(text)") { return url }
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    /// Refreshes the grid card's snapshot of what is on screen.
    public func takeSnapshot() {
        guard webView.window != nil else { return }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            MainActor.assumeIsolated {
                if let image { self?.snapshot = image }
            }
        }
    }
}

/// Keeps a page opened on the iPhone from loading the Mac's own addresses, and
/// notes when the phone cannot reach a host (both shown over the page).
@MainActor
final class MacAddressGuard: NSObject, WKNavigationDelegate {
    weak var model: BrowserTabModel?

    init(model: BrowserTabModel) { self.model = model }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame != false, let target = action.request.url, PhoneReach(target) == .macOnly {
            model?.refuse(target)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A navigation this guard let through (Back from a refused address too): the page shows again.
        model?.clearProblem()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        let error = error as NSError
        // A navigation replaced by the next one, or one this guard cancelled.
        guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled,
              !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }
        let failed = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        if let failed { model?.unreachable(failed, error) }
    }
}

/// The live page: the tab's web view, inset under the status bar and the tab
/// toolbar, reporting finger scrolls to collapse the toolbar.
struct BrowserPage: UIViewRepresentable {
    let model: BrowserTabModel
    var insets: EdgeInsets
    var isZoomGestureActive: Bool
    var reportScroll: @MainActor (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        let web = model.webView
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(web)
        context.coordinator.attach(web.scrollView)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let scroll = model.webView.scrollView
        let inset = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        if scroll.contentInset != inset {
            let atTop = scroll.contentOffset.y <= -scroll.contentInset.top + 1
            scroll.contentInset = inset
            scroll.verticalScrollIndicatorInsets = inset
            if atTop { scroll.contentOffset.y = -inset.top }
        }
        scroll.pinchGestureRecognizer?.isEnabled = !isZoomGestureActive
        context.coordinator.report = reportScroll
    }

    @MainActor
    final class Coordinator {
        var report: (@MainActor (CGFloat) -> Void)?
        private var observation: NSKeyValueObservation?
        private var last: CGFloat = 0

        func attach(_ scroll: UIScrollView) {
            last = scroll.contentOffset.y
            observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let y = scroll.contentOffset.y
                    if scroll.isDragging { self.report?(self.last - y) }
                    self.last = y
                }
            }
        }
    }
}

/// A browser tab's grid card: its last snapshot, else a blank page.
struct BrowserCard: View {
    let model: BrowserTabModel?
    var insets: EdgeInsets

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemBackground)
            if let image = model?.snapshot {
                GeometryReader { geo in
                    Image(uiImage: image).resizable().interpolation(.medium)
                        .frame(width: geo.size.width, height: geo.size.width * image.size.height / max(1, image.size.width))
                }
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
#endif
