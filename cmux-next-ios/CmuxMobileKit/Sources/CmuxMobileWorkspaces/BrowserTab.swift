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
    /// The web view's own history; a problem card is a step of its own (Back clears it).
    private var historyBack = false
    public var canGoBack: Bool { historyBack || problem != nil }
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
    /// The person navigated (typed an address, followed a link, went back or forward),
    /// as opposed to the page redirecting by itself.
    @ObservationIgnored var personNavigated: (@MainActor () -> Void)?
    /// Whether a Mac `localhost:<port>` page may load here (answered at once). Nil:
    /// those pages are the Mac's only.
    @ObservationIgnored var loopbackPolicy: (@MainActor (URL) -> LoopbackForward)?
    /// Readies the page's port (forwarded to the Mac's loopback) before it loads.
    @ObservationIgnored var forwardLoopback: (@MainActor (URL) async -> LoopbackForward)?
    /// The address this tab itself is loading (the address bar, Open on iPhone, a
    /// restored page): a navigation the person started, which may open a new port.
    @ObservationIgnored var ownLoad: URL?
    /// Whether the page's port already forwards to this tab's Mac (its redirects and
    /// same-port links need no new port).
    @ObservationIgnored var loopbackIsOpen: (@MainActor (URL) -> Bool)?
    /// The Mac's last refusal of a forwarded port ("Nothing is listening on port 3000 on this Mac.").
    @ObservationIgnored var loopbackRefusal: (@MainActor (URL) -> String?)?
    /// Opened on the iPhone from a Mac's page: the Mac's own addresses (`localhost`)
    /// are not loaded here, and an unreachable host says so.
    @ObservationIgnored private var guardian: MacAddressGuard?

    public struct Problem: Equatable {
        public var url: URL
        /// Only the Mac can open it (its `localhost`, a `file:` page); else the phone could not reach it.
        public var isMacOnly: Bool
        /// A private, LAN or tailnet host (the Mac may reach it when the phone can't).
        public var isPrivateNetwork: Bool
        /// iOS refused a plain `http://` page (App Transport Security).
        public var isInsecure = false
        public var message: String
        /// What the card says instead of its usual explanation.
        public var detail: String?
    }

    /// Whether a Mac `localhost:<port>` page may load here.
    enum LoopbackForward: Equatable {
        /// This iPhone listens on the port and forwards it to the Mac.
        case forwarded
        /// Only the Mac can show it (its `detail`, if any, says why).
        case macOnly(detail: String?)
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
        let reach = PhoneReach(target)
        if guardian != nil, reach == .macOnly {
            refuse(target)
            return
        }
        if guardian != nil, reach == .macLoopback {
            if case .macOnly(let detail) = loopbackPolicy?(target) ?? .macOnly(detail: nil) {
                refuse(target, detail: detail)
                return
            }
            ownLoad = target
        }
        problem = nil
        // The address bar shows where the page is going at once (as Safari's does).
        url = target
        urlChanged?(target)
        webView.load(URLRequest(url: target))
    }

    func refuse(_ target: URL, detail: String? = nil) {
        url = target
        problem = Problem(url: target, isMacOnly: true, isPrivateNetwork: false, message: "", detail: detail)
    }

    func unreachable(_ target: URL, _ error: any Error) {
        let code = (error as NSError).code
        url = target
        problem = Problem(url: target, isMacOnly: false, isPrivateNetwork: PhoneReach(target) == .privateNetwork,
                          isInsecure: (error as NSError).domain == NSURLErrorDomain && code == NSURLErrorAppTransportSecurityRequiresSecureConnection,
                          message: error.localizedDescription,
                          detail: PhoneReach(target) == .macLoopback ? loopbackRefusal?(target) : nil)
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
            // A card keeps the address that failed in the bar (as Safari does); WebKit
            // puts its own back on the last page that loaded.
            guard let value, model.problem == nil else { return }
            model.url = value
            model.urlChanged?(value)
        }
        watch(\.title) { model, value in model.title = value ?? "" }
        watch(\.canGoBack) { model, value in model.historyBack = value }
        watch(\.canGoForward) { model, value in model.canGoForward = value }
        watch(\.isLoading) { model, value in model.isLoading = value }
        watch(\.estimatedProgress) { model, value in model.progress = value }
    }

    public var host: String { url.map(TabsKitAddress.displayLabel(for:)) ?? "" }

    public func goBack() {
        // Back from a card: the page under it (the address the person asked for never loaded).
        if problem != nil {
            problem = nil
            url = webView.url
            // The tab opens here again at this page, not the address that failed.
            if let page = webView.url { urlChanged?(page) }
            return
        }
        personNavigated?()
        _ = webView.goBack()
    }

    public func goForward() {
        personNavigated?()
        _ = webView.goForward()
    }
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
        personNavigated?()
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

    /// Same scheme, host and port.
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased()
            && PhoneReach.port(a) == PhoneReach.port(b)
    }

    /// What a page loads itself; anything else belongs to another app.
    static let pageSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript"]

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame != false, let target = action.request.url else {
            decisionHandler(.allow)
            return
        }
        // A tap or Back/Forward; a form a page submits by itself (a sign-in step) is not the person's.
        if [.linkActivated, .backForward].contains(action.navigationType) { model?.personNavigated?() }
        let reach = PhoneReach(target)
        if reach == .macLoopback, let model, let policy = model.loopbackPolicy, let forward = model.forwardLoopback {
            if case .macOnly(let detail) = policy(target) {
                model.refuse(target, detail: detail)
                decisionHandler(.cancel)
                return
            }
            // A new port opens only for a navigation the person started, or one from
            // the same loopback origin (the dev app's own links); never a page's
            // script or form sending this iPhone into the Mac's loopback.
            // WebKit normalizes the address (`localhost:3000` asks for `localhost:3000/`).
            let own = model.ownLoad.map { Self.sameOrigin($0, target) } ?? false
            model.ownLoad = nil
            // `sourceFrame` is nil for some navigations despite its Swift type.
            let source = (action.sourceFrame as WKFrameInfo?)?.request.url
            let sameOrigin = source.map { Self.sameOrigin($0, target) } ?? false
            let open = model.loopbackIsOpen?(target) ?? false
            guard own || open || sameOrigin || [.linkActivated, .backForward].contains(action.navigationType) else {
                model.refuse(target, detail: String(localized: "A page tried to open \(WorkspaceTabsSource.addressLabel(target)). Type it in the address bar to open it on this iPhone, or mirror it from the Mac."))
                decisionHandler(.cancel)
                return
            }
            // The Mac's dev server: this iPhone's listener on the port must be up first.
            // task-owner: one navigation's decision; WebKit waits for it
            Task { @MainActor in
                switch await forward(target) {
                case .forwarded:
                    decisionHandler(.allow)
                case .macOnly(let detail):
                    model.refuse(target, detail: detail)
                    decisionHandler(.cancel)
                }
            }
            return
        }
        if reach == .macOnly || reach == .macLoopback {
            model?.refuse(target)
            decisionHandler(.cancel)
            return
        }
        // mailto:, tel:, an App Store or app link: iOS opens it, as Safari does.
        let scheme = target.scheme?.lowercased() ?? ""
        if !Self.pageSchemes.contains(scheme) {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated { UIApplication.shared.open(target) }
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
