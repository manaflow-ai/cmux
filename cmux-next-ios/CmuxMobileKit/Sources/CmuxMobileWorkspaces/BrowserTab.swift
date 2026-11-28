#if os(iOS)
import enum CmuxMobileModel.UserFacingError
import Observation
import CmuxMobileDesign
import SwiftUI
import UIKit
import WebKit
import Network
import CmuxMobileBrowserStream
import CmuxMobileDesign
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
    public var canGoBack: Bool { (pageHistory.isEmpty ? historyBack : historyIndex > 0) || problem != nil }
    private var historyForward = false
    public var canGoForward: Bool { pageHistory.isEmpty ? historyForward : historyIndex + 1 < pageHistory.count }
    private struct PageHistoryEntry {
        let view: WKWebView
        let item: WKBackForwardListItem
    }
    private var pageHistory: [PageHistoryEntry] = []
    private var historyIndex = -1
    @ObservationIgnored private var historySync: Task<Void, Never>?
    @ObservationIgnored private var awaitingViewCommit = false
    @ObservationIgnored private var pendingHistoryItem: WKBackForwardListItem?
    @ObservationIgnored private var nativeHistoryItems: Set<ObjectIdentifier> = []
    public private(set) var isLoading = false
    public private(set) var progress: Double = 1
    public private(set) var snapshot: UIImage?
    /// A snapshot was taken (`WorkspaceTabsSource` keeps it as the tab's last-known picture).
    @ObservationIgnored var onSnapshot: (@MainActor (UIImage) -> Void)?
    /// Why the phone's page shows no page (a tab opened on the iPhone from the Mac):
    /// an address only the Mac can open, or a host this iPhone could not reach.
    public private(set) var problem: Problem?
    public private(set) var webView: WKWebView
    @ObservationIgnored private let ordinaryWebView: WKWebView
    @ObservationIgnored private var proxyWebView: WKWebView?
    @ObservationIgnored private let proxyStoreIdentifier: UUID
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
    /// Prepares an origin-preserving CONNECT route for a named private host.
    @ObservationIgnored var preparePrivateHost: (@MainActor (URL) async -> LocalhostForwarder.ProxyRoute?)?
    /// The address this tab itself is loading (the address bar, Open on iPhone, a
    /// restored page): a navigation the person started, which may open a new port.
    @ObservationIgnored var ownLoad: URL?
    /// Whether the page's port already forwards to this tab's Mac (its redirects and
    /// same-port links need no new port).
    @ObservationIgnored var loopbackIsOpen: (@MainActor (URL) -> Bool)?
    /// The Mac's last refusal of a forwarded port ("Nothing is listening on port 3000 on this Mac.").
    @ObservationIgnored var loopbackRefusal: (@MainActor (URL) -> String?)?
    /// Reads an HTML file on the tab's Mac (`file:///…/report.html`) over the link (nil:
    /// such a page is the Mac's only).
    @ObservationIgnored var readMacHTML: (@MainActor (URL) async throws -> String)?
    /// The Mac file this page shows (its address bar reads it, not `about:blank`).
    @ObservationIgnored private(set) var macFile: URL?
    @ObservationIgnored private var macFileRead: Task<Void, Never>?
    @ObservationIgnored private var forwardingLoad: Task<Void, Never>?
    @ObservationIgnored private var navigationGeneration: UInt = 0

    /// Invalidates pending policy decisions when another navigation or mirroring wins.
    @discardableResult
    func beginNavigation(preservingHistory: Bool = false) -> UInt {
        if !preservingHistory, pendingHistoryItem != nil {
            pendingHistoryItem = nil
            awaitingViewCommit = false
        }
        navigationGeneration &+= 1
        return navigationGeneration
    }

    func isCurrentNavigation(_ generation: UInt) -> Bool { navigationGeneration == generation }
    /// Opened on the iPhone from a Mac's page: the Mac's own addresses (`localhost`)
    /// are not loaded here, and an unreachable host says so.
    @ObservationIgnored private var guardian: MacAddressGuard?
    @ObservationIgnored private var privateProxyRoutes: [LocalhostForwarder.Target: LocalhostForwarder.ProxyRoute] = [:]

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

    public init(url: URL?, guardsMacAddresses: Bool = false, storeIdentifier: UUID? = nil) {
        let ordinary = Self.makeWebView(store: .default())
        ordinaryWebView = ordinary
        webView = ordinary
        proxyStoreIdentifier = storeIdentifier ?? UUID()
        self.url = url
        if guardsMacAddresses {
            let guardian = MacAddressGuard(model: self)
            self.guardian = guardian
            webView.navigationDelegate = guardian
        }
        observe()
        if let url { load(url) }
    }

    private static func makeWebView(store: WKWebsiteDataStore) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        return view
    }

    /// A proxy configuration belongs to its data store. Ordinary pages retain the
    /// shared store and history; private pages never install routes in that store.
    private func activate(_ view: WKWebView) {
        guard webView !== view else { return }
        webView.stopLoading()
        webView.pauseAllMediaPlayback()
        observations.removeAll()
        // The retained view initially still points at its old page. Do not move
        // the bridge cursor there while a new navigation is replacing it.
        awaitingViewCommit = true
        webView = view
        view.navigationDelegate = guardian
        snapshot = nil
        observe()
    }

    func activateOrdinaryPage() { activate(ordinaryWebView) }

    /// Loads an address; on a page opened from the Mac, one only the Mac can open
    /// shows why instead.
    public func load(_ target: URL) {
        let generation = beginNavigation()
        ownLoad = nil
        let reach = PhoneReach(target)
        forwardingLoad?.cancel()
        forwardingLoad = nil
        macFileRead?.cancel()
        macFileRead = nil
        if guardian != nil, BrowserPagePlacement.isMacHTMLFile(target), let read = readMacHTML {
            loadMacFile(target, read: read)
            return
        }
        macFile = nil
        if reach != .privateNetwork { activateOrdinaryPage() }
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
        if guardian != nil, reach == .privateNetwork, preparePrivateHost != nil {
            ownLoad = target
            problem = nil
            url = target
            urlChanged?(target)
            forwardingLoad = Task { @MainActor [weak self] in
                guard let self, self.isCurrentNavigation(generation), await self.preparePrivateHostRoute(target), !Task.isCancelled,
                      self.isCurrentNavigation(generation) else {
                    if let self, !Task.isCancelled, self.isCurrentNavigation(generation) { self.refuse(target) }
                    return
                }
                self.webView.load(URLRequest(url: target))
            }
            return
        }
        problem = nil
        // The address bar shows where the page is going at once (as Safari's does).
        url = target
        urlChanged?(target)
        webView.load(URLRequest(url: target))
    }

    /// An HTML file on the Mac: its bytes come over the link and load here as a page
    /// (relative images and scripts beside it stay on the Mac; a self-contained report shows whole).
    private func loadMacFile(_ target: URL, read: @escaping @MainActor (URL) async throws -> String) {
        activateOrdinaryPage()
        problem = nil
        macFile = target
        url = target
        urlChanged?(target)
        isLoading = true
        progress = 0.1
        // task-owner: this tab's one Mac file read; the next load cancels it
        macFileRead = Task { [weak self] in
            do {
                let html = try await read(target)
                guard let self, !Task.isCancelled, self.macFile == target else { return }
                self.webView.loadHTMLString(html, baseURL: nil)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.macFile == target else { return }
                self.isLoading = false
                self.progress = 1
                let name = target.lastPathComponent
                let reason = error is MacHTMLUnavailable ? "" : UserFacingError.message(error, fallback: "")
                self.refuse(target, detail: reason.isEmpty
                    ? String(localized: "This iPhone couldn't read \(name) from the Mac. The mirrored page can show it.")
                    : String(localized: "This iPhone couldn't read \(name) from the Mac: \(reason) The mirrored page can show it."))
            }
        }
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
                          message: UserFacingError.message(error, fallback: "This page couldn't load."),
                          detail: PhoneReach(target) == .macLoopback ? loopbackRefusal?(target) : nil)
    }

    public func clearProblem() { problem = nil }

    /// Installs a named-host route while leaving the original URL request intact.
    func preparePrivateHostRoute(_ target: URL) async -> Bool {
        let generation = navigationGeneration
        guard let preparePrivateHost, let route = await preparePrivateHost(target), !Task.isCancelled,
              isCurrentNavigation(generation) else { return false }
        if proxyWebView == nil {
            proxyWebView = Self.makeWebView(store: WKWebsiteDataStore(forIdentifier: proxyStoreIdentifier))
        }
        guard let proxyWebView else { return false }
        privateProxyRoutes[route.target] = route
        // A host shares one CONNECT endpoint across its allowed destination ports.
        let hosts = Dictionary(grouping: privateProxyRoutes.values, by: { $0.target.host })
        proxyWebView.configuration.websiteDataStore.proxyConfigurations = hosts.values.compactMap { $0.first?.configuration }
        activate(proxyWebView)
        return true
    }

    /// Stops loading and media behind the mirror (the page stays for the next visit).
    func pause() {
        beginNavigation()
        ownLoad = nil
        webView.stopLoading()
        webView.pauseAllMediaPlayback()
        forwardingLoad?.cancel()
        privateProxyRoutes.removeAll()
        proxyWebView?.configuration.websiteDataStore.proxyConfigurations = []
    }

    func hasPrivateRoute(_ target: URL) -> Bool {
        PhoneReach.forwardingTarget(target).map { privateProxyRoutes[$0] != nil } ?? false
    }

    private func observe() {
        func watch<V: Sendable>(_ path: KeyPath<WKWebView, V>, _ apply: @escaping @MainActor (BrowserTabModel, V) -> Void) {
            observations.append(webView.observe(path, options: [.initial, .new]) { [weak self] web, _ in
                let value = web[keyPath: path]
                MainActor.assumeIsolated {
                    guard let self, self.webView === web else { return }
                    apply(self, value)
                }
            })
        }
        watch(\.url) { model, value in
            model.scheduleHistorySync()
            // A card keeps the address that failed in the bar (as Safari does); WebKit
            // puts its own back on the last page that loaded.
            guard let value, model.problem == nil else { return }
            // A Mac file's page loads as a string (`about:blank`): the bar keeps the file.
            if value.absoluteString == "about:blank", let file = model.macFile {
                model.url = file
                return
            }
            model.url = value
            model.urlChanged?(value)
        }
        watch(\.title) { model, value in model.title = value ?? "" }
        watch(\.canGoBack) { model, value in
            model.historyBack = value
            model.scheduleHistorySync()
        }
        watch(\.canGoForward) { model, value in
            model.historyForward = value
            model.scheduleHistorySync()
        }
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
        if !awaitingViewCommit { reconcileHistory() }
        if pageHistory.isEmpty { _ = webView.goBack() }
        else { visitHistory(at: historyIndex - 1) }
    }

    public func goForward() {
        personNavigated?()
        if !awaitingViewCommit { reconcileHistory() }
        if pageHistory.isEmpty { _ = webView.goForward() }
        else { visitHistory(at: historyIndex + 1) }
    }

    /// WebKit owns history. Only live back/current/forward items belong in the
    /// bridge: its size stays bounded by the two views' native history lists.
    func pageCommitted(in view: WKWebView) {
        guard view === webView else { return }
        awaitingViewCommit = false
        pendingHistoryItem = nil
        reconcileHistory()
    }

    /// pushState, replaceState and fragment navigation need no didCommit callback.
    /// Coalesce WebKit's URL/back/forward KVO, after it updates the native lists.
    private func scheduleHistorySync() {
        guard historySync == nil else { return }
        // task-owner: one coalesced history read for this tab, no polling
        historySync = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.historySync = nil
            if let target = self.pendingHistoryItem, self.webView.backForwardList.currentItem === target {
                self.pendingHistoryItem = nil
                self.awaitingViewCommit = false
            }
            if !self.awaitingViewCommit { self.reconcileHistory() }
        }
    }

    private func reconcileHistory() {
        let selected = pageHistory.indices.contains(historyIndex) ? pageHistory[historyIndex] : nil
        var live = Set<ObjectIdentifier>()
        for view in [ordinaryWebView, proxyWebView].compactMap({ $0 }) {
            let list = view.backForwardList
            for item in list.backList + [list.currentItem].compactMap({ $0 }) + list.forwardList {
                live.insert(ObjectIdentifier(item))
            }
        }
        let previouslyNative = nativeHistoryItems
        nativeHistoryItems = live
        pageHistory.removeAll { !live.contains(ObjectIdentifier($0.item)) }
        historyIndex = selected.flatMap { selected in
            pageHistory.firstIndex { $0.view === selected.view && $0.item === selected.item }
        } ?? min(historyIndex, pageHistory.count - 1)
        guard let item = webView.backForwardList.currentItem else { return }
        if let index = pageHistory.firstIndex(where: { $0.view === webView && $0.item === item }) {
            historyIndex = index
            return
        }
        // A new item discards global Forward, just as a new native navigation
        // does. Include any same-document items batched into this KVO delivery.
        pageHistory = Array(pageHistory.prefix(historyIndex + 1))
        let known = Set(pageHistory.map { ObjectIdentifier($0.item) })
        for entry in webView.backForwardList.backList + [item] {
            let identity = ObjectIdentifier(entry)
            // An old native entry may have been discarded from global Forward
            // while its inactive view retained it. Never resurrect that branch.
            guard !known.contains(identity), entry === item || !previouslyNative.contains(identity) else { continue }
            pageHistory.append(PageHistoryEntry(view: webView, item: entry))
        }
        historyIndex = pageHistory.count - 1
    }

    private func visitHistory(at index: Int) {
        guard pageHistory.indices.contains(index) else { return }
        let entry = pageHistory[index]
        let generation = beginNavigation()
        forwardingLoad?.cancel()
        // task-owner: a history traversal, cancelled by the next load or traversal
        forwardingLoad = Task { @MainActor [weak self] in
            guard let self, self.isCurrentNavigation(generation) else { return }
            if entry.view === self.proxyWebView {
                guard await self.preparePrivateHostRoute(entry.item.url), !Task.isCancelled else { return }
            }
            guard !Task.isCancelled, self.isCurrentNavigation(generation) else { return }
            self.historyIndex = index
            self.activate(entry.view)
            if entry.view.backForwardList.currentItem !== entry.item {
                self.awaitingViewCommit = true
                self.pendingHistoryItem = entry.item
                self.ownLoad = entry.item.url
                entry.view.go(to: entry.item)
            } else {
                self.awaitingViewCommit = false
                self.ownLoad = nil
                self.url = entry.item.url
                self.urlChanged?(entry.item.url)
            }
        }
    }
    public func reloadOrStop() {
        if isLoading {
            if let read = macFileRead {
                read.cancel()
                macFileRead = nil
                isLoading = false
                progress = 1
            }
            webView.stopLoading()
        } else if let problem {
            // Try Again: the failed address, not the last page that loaded.
            load(problem.url)
        } else if let file = macFile, webView.url?.absoluteString == "about:blank" {
            // Reload a Mac file: read it again (the agent may have rewritten it).
            load(file)
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
                guard let image, let self else { return }
                self.snapshot = image
                self.onSnapshot?(image)
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
            && PhoneReach.portForAddress(a) == PhoneReach.portForAddress(b)
    }

    /// What a page loads itself; anything else belongs to another app.
    static let pageSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript"]

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame != false, let target = action.request.url else {
            decisionHandler(.allow)
            return
        }
        guard let model, model.webView === webView else {
            decisionHandler(.cancel)
            return
        }
        let generation = model.beginNavigation(preservingHistory: action.navigationType == .backForward)
        // A tap or Back/Forward; a form a page submits by itself (a sign-in step) is not the person's.
        if [.linkActivated, .backForward].contains(action.navigationType) { model.personNavigated?() }
        let reach = PhoneReach(target)
        if reach == .privateNetwork, model.preparePrivateHost != nil {
            let own = model.ownLoad.map { Self.sameOrigin($0, target) } ?? false
            model.ownLoad = nil
            let source = (action.sourceFrame as WKFrameInfo?)?.request.url
            guard Self.admitsPrivateNavigation(target: target, own: own, source: source,
                                              isOpen: model.hasPrivateRoute(target), type: action.navigationType) else {
                model.refuse(target, detail: String(localized: "A page tried to open \(WorkspaceTabsSource.addressLabel(target)). Type it in the address bar to open it on this iPhone, or mirror it from the Mac."))
                decisionHandler(.cancel)
                return
            }
            Task { @MainActor in
                guard model.isCurrentNavigation(generation), await model.preparePrivateHostRoute(target),
                      model.isCurrentNavigation(generation) else {
                    if model.isCurrentNavigation(generation) { model.refuse(target, detail: String(localized: "This private host could not be reached through the Mac.")) }
                    decisionHandler(.cancel)
                    return
                }
                if model.webView !== webView {
                    decisionHandler(.cancel)
                    model.ownLoad = target
                    model.webView.load(action.request)
                } else {
                    decisionHandler(.allow)
                }
            }
            return
        }
        if reach == .macLoopback, let policy = model.loopbackPolicy, let forward = model.forwardLoopback {
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
                guard model.isCurrentNavigation(generation) else { decisionHandler(.cancel); return }
                let result = await forward(target)
                guard model.isCurrentNavigation(generation) else { decisionHandler(.cancel); return }
                switch result {
                case .forwarded:
                    model.activateOrdinaryPage()
                    if model.webView !== webView {
                        decisionHandler(.cancel)
                        model.ownLoad = target
                        model.webView.load(action.request)
                    } else {
                        decisionHandler(.allow)
                    }
                case .macOnly(let detail):
                    model.refuse(target, detail: detail)
                    decisionHandler(.cancel)
                }
            }
            return
        }
        // A link to another HTML file on the Mac: read over the link like the first one.
        if reach == .macOnly, BrowserPagePlacement.isMacHTMLFile(target), model.readMacHTML != nil {
            decisionHandler(.cancel)
            model.personNavigated?()
            model.load(target)
            return
        }
        if reach == .macOnly || reach == .macLoopback {
            model.refuse(target)
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
        if ["http", "https"].contains(scheme) {
            model.activateOrdinaryPage()
            if model.webView !== webView {
                decisionHandler(.cancel)
                model.webView.load(action.request)
                return
            }
        }
        decisionHandler(.allow)
    }

    static func admitsPrivateNavigation(target: URL, own: Bool, source: URL?, isOpen: Bool,
                                        type: WKNavigationType) -> Bool {
        own || isOpen || source.map { sameOrigin($0, target) } == true
            || [.linkActivated, .backForward].contains(type)
    }

    /// A Mac dev server on `https://localhost:<port>` with its own certificate (self-signed,
    /// mkcert, `vite --https`): this iPhone's listener on the port is the forward to the
    /// Mac's loopback (RFD 0089), so the page trusts that certificate as the Mac's browser
    /// does for its own `localhost`. Every other host keeps iOS's usual check.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
              let model, Self.trustsDevCertificate(host: space.host, port: space.port,
                                                   isForwarded: { model.loopbackIsOpen?($0) ?? false })
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// Whether a TLS server at `host:port` is a Mac loopback dev server this iPhone forwards.
    static func trustsDevCertificate(host: String, port: Int, isForwarded: (URL) -> Bool) -> Bool {
        let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard (1...65535).contains(port), let url = URL(string: "https://\(name):\(port)/"),
              PhoneReach(url) == .macLoopback else { return false }
        return isForwarded(url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        model?.pageCommitted(in: webView)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Inactive retained views must not change the active page's state.
        guard let model, model.webView === webView else { return }
        model.clearProblem()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard let model, model.webView === webView else { return }
        let error = error as NSError
        // A navigation replaced by the next one, or one this guard cancelled.
        guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled,
              !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }
        let failed = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        if let failed { model.unreachable(failed, error) }
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
        context.coordinator.installedWebView = web
        context.coordinator.attach(web.scrollView)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let web = model.webView
        if web.superview !== container {
            if let previous = context.coordinator.installedWebView, previous.superview === container {
                previous.removeFromSuperview()
            }
            web.removeFromSuperview()
            web.frame = container.bounds
            web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(web)
            context.coordinator.installedWebView = web
            context.coordinator.attach(web.scrollView)
        }
        let scroll = web.scrollView
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
        weak var installedWebView: WKWebView?
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

/// A browser tab's grid card: its last snapshot, else its last-known picture, else the page's background.
struct BrowserCard: View {
    let model: BrowserTabModel?
    var insets: EdgeInsets
    /// The tab's last-known picture (`TabCardSnapshots`): shown until this launch has a snapshot.
    var lastKnown: UIImage?
    var lastKnownPixelWidth: Int = 0
    var lastKnownPixelHeight: Int = 0
    /// The card's tab, for the UI tests' face probe (`TabCardFaceRecord`).
    var tabID: String?
    /// The page's host, for the site monogram (`SiteMonogram`, off by default).
    var host: String?
    @AppStorage(CmuxMobilePreferences.Key.tabCardMonograms) private var monograms = CmuxMobilePreferences.defaultTabCardMonograms

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemBackground)
            if let image = model?.snapshot {
                GeometryReader { geo in
                    Image(uiImage: image).resizable().interpolation(.medium)
                        .frame(width: geo.size.width, height: geo.size.width * image.size.height / max(1, image.size.width))
                }
            } else if lastKnown != nil || (lastKnownPixelWidth > 0 && lastKnownPixelHeight > 0) {
                TabSnapshotPicture(image: lastKnown, pixelWidth: lastKnownPixelWidth, pixelHeight: lastKnownPixelHeight)
            } else if monograms, SiteMonogram.letter(host) != nil {
                SiteMonogramFace(host: host)
            }
            // No picture yet: the page's background, never a stand-in glyph (Leo, 2026-11-24, on
            // a grid of globes: "wer need to chase all these placeholders doen and prevent them").
        }
        .modifier(TabCardFaceRecord(tabID: tabID,
                                    face: model?.snapshot != nil ? "snapshot" : lastKnown != nil || (lastKnownPixelWidth > 0 && lastKnownPixelHeight > 0) ? "lastKnown"
                                        : monograms && SiteMonogram.letter(host) != nil ? "monogram" : "nothing"))
    }
}
#endif
