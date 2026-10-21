import CmuxTabsKit
import Observation
import SwiftUI
import WebKit

/// One web tab: a WKWebView kept alive for the tab's lifetime and its
/// observed navigation state.
@MainActor
@Observable
final class DemoWebPage {
    @ObservationIgnored let webView: WKWebView
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress = 0.0
    /// Called when a load finishes (the tab refreshes its thumbnail).
    @ObservationIgnored var onLoaded: (() -> Void)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let panRelay = PanRelay()

    init(url: URL, configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isInspectable = true
        webView.scrollView.panGestureRecognizer.addTarget(panRelay, action: #selector(PanRelay.pan(_:)))
        observations = [watch(\.title), watch(\.url), watch(\.canGoBack), watch(\.canGoForward), watch(\.isLoading), watch(\.estimatedProgress)]
        webView.load(URLRequest(url: url))
    }

    private func watch<Value>(_ keyPath: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
        webView.observe(keyPath, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    private func sync() {
        let wasLoading = isLoading
        title = webView.title ?? ""
        url = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
        if wasLoading, !isLoading { onLoaded?() }
    }

    /// Finger travel on the page goes to the toolbar (collapse / expand).
    func setScrollHandler(_ handler: @escaping @MainActor (CGFloat) -> Void) {
        panRelay.handler = handler
    }

    func snapshot() async -> UIImage? {
        try? await webView.takeSnapshot(configuration: nil)
    }

    /// The tab as the kit shows it.
    func tab(id: String) -> TabsKitTab {
        let query = url.flatMap(DemoSite.searchQuery)
        let isStart = url == nil || url == DemoSite.start
        let address: TabsKitAddress
        if isStart {
            address = .placeholder("Search or enter website")
        } else if let query {
            address = .url(display: query, editingText: query, isSearch: true)
        } else {
            let display = url.map { u in u.scheme == DemoSite.scheme ? (u.host() ?? "") + u.path() : (u.host() ?? u.absoluteString) } ?? ""
            address = .url(display: display, editingText: url?.absoluteString ?? "")
        }
        return TabsKitTab(id: id, kind: .web, title: isStart ? "Start Page" : (title.isEmpty ? address.label : title),
                          subtitle: url?.absoluteString ?? "", systemImage: "globe", address: address,
                          navigation: TabsKitNavigationState(canGoBack: canGoBack, canGoForward: canGoForward, isLoading: isLoading, progress: progress),
                          features: .web,
                          statusBarStyle: TabsKitStatusBarStyle(over: DemoSite.headerColor(for: url)))
    }

    func history(_ direction: TabsKitHistoryDirection) -> [TabsKitHistoryItem] {
        let list = webView.backForwardList
        let items = direction == .back ? Array(list.backList.reversed()) : list.forwardList
        return items.enumerated().map { index, item in
            TabsKitHistoryItem(id: "\(direction)-\(index)", title: item.title ?? item.url.absoluteString, subtitle: item.url.absoluteString)
        }
    }

    func go(to item: TabsKitHistoryItem) {
        for direction in [TabsKitHistoryDirection.back, .forward] {
            let list = webView.backForwardList
            let items = direction == .back ? Array(list.backList.reversed()) : list.forwardList
            if let index = history(direction).firstIndex(where: { $0.id == item.id }), index < items.count {
                webView.go(to: items[index])
                return
            }
        }
    }
}

/// Reports the scroll view's pan translation deltas (positive = finger down).
@MainActor
final class PanRelay: NSObject {
    var handler: (@MainActor (CGFloat) -> Void)?
    private var last: CGFloat = 0

    @objc func pan(_ g: UIPanGestureRecognizer) {
        let y = g.translation(in: g.view).y
        switch g.state {
        case .began:
            last = y
        case .changed:
            handler?(y - last)
            last = y
        default:
            break
        }
    }
}

/// Hosts a tab's web view, laid out at the full screen size with insets for
/// the status bar and the toolbar.
struct DemoWebView: UIViewRepresentable {
    let page: DemoWebPage
    let context: TabsKitContentContext

    func makeUIView(context: Context) -> WKWebView { page.webView }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let insets = UIEdgeInsets(top: self.context.safeAreaInsets.top, left: 0, bottom: self.context.safeAreaInsets.bottom, right: 0)
        if webView.scrollView.contentInset != insets {
            webView.scrollView.contentInset = insets
            webView.scrollView.verticalScrollIndicatorInsets = insets
        }
        // While a pinch drives the tab zoom the page must not zoom too.
        webView.scrollView.pinchGestureRecognizer?.isEnabled = !self.context.isZoomGestureActive
        let ctx = self.context
        page.setScrollHandler { ctx.reportScroll(fingerDelta: $0) }
    }
}
