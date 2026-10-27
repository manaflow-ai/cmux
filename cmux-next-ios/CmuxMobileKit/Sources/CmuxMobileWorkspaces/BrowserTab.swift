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
    @ObservationIgnored public let webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    public init(url: URL?) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        self.url = url
        observe()
        if let url { webView.load(URLRequest(url: url)) }
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
        watch(\.url) { model, value in if let value { model.url = value } }
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
        if isLoading { webView.stopLoading() } else { _ = webView.reload() }
    }

    /// A URL, a bare host, or a search.
    public func navigate(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = Self.url(for: trimmed) else { return }
        webView.load(URLRequest(url: target))
    }

    nonisolated static func url(for text: String) -> URL? {
        if text.isEmpty { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) { return url }
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
