import Foundation
import Combine
import WebKit
import AppKit

enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckduckgo
    case bing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    func searchURL(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components: URLComponents?
        switch self {
        case .google:
            components = URLComponents(string: "https://www.google.com/search")
        case .duckduckgo:
            components = URLComponents(string: "https://duckduckgo.com/")
        case .bing:
            components = URLComponents(string: "https://www.bing.com/search")
        }

        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
        ]
        return components?.url
    }
}

enum BrowserSearchSettings {
    static let searchEngineKey = "browserSearchEngine"
    static let searchSuggestionsEnabledKey = "browserSearchSuggestionsEnabled"
    static let defaultSearchEngine: BrowserSearchEngine = .google
    static let defaultSearchSuggestionsEnabled: Bool = true

    static func currentSearchEngine(defaults: UserDefaults = .standard) -> BrowserSearchEngine {
        guard let raw = defaults.string(forKey: searchEngineKey),
              let engine = BrowserSearchEngine(rawValue: raw) else {
            return defaultSearchEngine
        }
        return engine
    }

    static func currentSearchSuggestionsEnabled(defaults: UserDefaults = .standard) -> Bool {
        // Mirror @AppStorage behavior: bool(forKey:) returns false if key doesn't exist.
        // Default to enabled unless user explicitly set a value.
        if defaults.object(forKey: searchSuggestionsEnabledKey) == nil {
            return defaultSearchSuggestionsEnabled
        }
        return defaults.bool(forKey: searchSuggestionsEnabledKey)
    }
}

enum BrowserUserAgentSettings {
    // Force a Safari UA. Some WebKit builds return a minimal UA without Version/Safari tokens,
    // and some installs may have legacy Chrome UA overrides. Both can cause Google to serve
    // fallback/old UIs or trigger bot checks.
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"
}

@MainActor
final class BrowserHistoryStore: ObservableObject {
    static let shared = BrowserHistoryStore()

    struct Entry: Codable, Identifiable, Hashable {
        let id: UUID
        var url: String
        var title: String?
        var lastVisited: Date
        var visitCount: Int
    }

    @Published private(set) var entries: [Entry] = []

    private let fileURL: URL?
    private var didLoad: Bool = false
    private var saveTask: Task<Void, Never>?
    private let maxEntries: Int = 5000

    init(fileURL: URL? = nil) {
        // Avoid calling @MainActor-isolated static methods from default argument context.
        self.fileURL = fileURL ?? BrowserHistoryStore.defaultHistoryFileURL()
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let fileURL else { return }

        Task.detached(priority: .utility) {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                return
            }

            let decoded: [Entry]
            do {
                decoded = try JSONDecoder().decode([Entry].self, from: data)
            } catch {
                return
            }

            await MainActor.run {
                // Most-recent first
                self.entries = decoded.sorted(by: { $0.lastVisited > $1.lastVisited })
            }
        }
    }

    func recordVisit(url: URL?, title: String?) {
        loadIfNeeded()

        guard let url else { return }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }

        let urlString = url.absoluteString
        guard urlString != "about:blank" else { return }

        if let idx = entries.firstIndex(where: { $0.url == urlString }) {
            entries[idx].lastVisited = Date()
            entries[idx].visitCount += 1
            // Prefer non-empty titles, but don't clobber an existing title with empty/whitespace.
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries[idx].title = title
            }
        } else {
            entries.insert(Entry(
                id: UUID(),
                url: urlString,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
                lastVisited: Date(),
                visitCount: 1
            ), at: 0)
        }

        // Keep most-recent first and bound size.
        entries.sort(by: { $0.lastVisited > $1.lastVisited })
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }

        scheduleSave()
    }

    func suggestions(for input: String, limit: Int = 10) -> [Entry] {
        loadIfNeeded()

        let q = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        func haystackMatches(_ s: String) -> Bool {
            s.lowercased().contains(q)
        }

        // Basic matching: contains in URL or title.
        // Sort by visit recency first; break ties by visit count.
        let matched = entries.filter { e in
            if haystackMatches(e.url) { return true }
            if let t = e.title, haystackMatches(t) { return true }
            return false
        }
        .sorted { a, b in
            if a.lastVisited != b.lastVisited { return a.lastVisited > b.lastVisited }
            return a.visitCount > b.visitCount
        }

        if matched.count <= limit { return matched }
        return Array(matched.prefix(limit))
    }

    private func scheduleSave() {
        guard let fileURL else { return }

        saveTask?.cancel()
        let snapshot = entries

        saveTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: 500_000_000) // debounce
            } catch {
                return
            }

            let dir = fileURL.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                return
            }

            let data: Data
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                data = try encoder.encode(snapshot)
            } catch {
                return
            }

            do {
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                return
            }
        }
    }

    nonisolated private static func defaultHistoryFileURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "cmux"
        let dir = appSupport.appendingPathComponent(bundleId, isDirectory: true)
        return dir.appendingPathComponent("browser_history.json", isDirectory: false)
    }
}

actor BrowserSearchSuggestionService {
    static let shared = BrowserSearchSuggestionService()

    func suggestions(engine: BrowserSearchEngine, query: String) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let url: URL?
        switch engine {
        case .google:
            var c = URLComponents(string: "https://suggestqueries.google.com/complete/search")
            c?.queryItems = [
                URLQueryItem(name: "client", value: "firefox"),
                URLQueryItem(name: "q", value: trimmed),
            ]
            url = c?.url
        case .duckduckgo:
            var c = URLComponents(string: "https://duckduckgo.com/ac/")
            c?.queryItems = [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "type", value: "list"),
            ]
            url = c?.url
        case .bing:
            var c = URLComponents(string: "https://www.bing.com/osjson.aspx")
            c?.queryItems = [
                URLQueryItem(name: "query", value: trimmed),
            ]
            url = c?.url
        }

        guard let url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        req.cachePolicy = .returnCacheDataElseLoad
        req.setValue(BrowserUserAgentSettings.safariUserAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            return []
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return []
        }

        switch engine {
        case .google, .bing:
            return parseOSJSON(data: data)
        case .duckduckgo:
            return parseDuckDuckGo(data: data)
        }
    }

    private func parseOSJSON(data: Data) -> [String] {
        // Format: [query, [suggestions...], ...]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              root.count >= 2,
              let list = root[1] as? [Any] else {
            return []
        }
        var out: [String] = []
        out.reserveCapacity(list.count)
        for item in list {
            guard let s = item as? String else { continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(trimmed)
        }
        return out
    }

    private func parseDuckDuckGo(data: Data) -> [String] {
        // Format: [{phrase:"..."}, ...]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        var out: [String] = []
        out.reserveCapacity(root.count)
        for item in root {
            guard let dict = item as? [String: Any],
                  let phrase = dict["phrase"] as? String else { continue }
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(trimmed)
        }
        return out
    }
}

/// BrowserPanel provides a WKWebView-based browser panel.
/// All browser panels share a WKProcessPool for cookie sharing.
@MainActor
final class BrowserPanel: Panel, ObservableObject {
    /// Shared process pool for cookie sharing across all browser panels
    private static let sharedProcessPool = WKProcessPool()

    let id: UUID
    let panelType: PanelType = .browser

    /// The workspace ID this panel belongs to
    private(set) var workspaceId: UUID

    /// The underlying web view
    let webView: WKWebView

    /// Prevent the omnibar from auto-focusing for a short window after explicit programmatic focus.
    /// This avoids races where SwiftUI focus state steals first responder back from WebKit.
    private var suppressOmnibarAutofocusUntil: Date?

    /// Published URL being displayed
    @Published private(set) var currentURL: URL?

    /// Published page title
    @Published private(set) var pageTitle: String = ""

    /// Published favicon (PNG data). When present, the tab bar can render it instead of a SF symbol.
    @Published private(set) var faviconPNGData: Data?

    /// Published loading state
    @Published private(set) var isLoading: Bool = false

    /// Published can go back state
    @Published private(set) var canGoBack: Bool = false

    /// Published can go forward state
    @Published private(set) var canGoForward: Bool = false

    /// Published estimated progress (0.0 - 1.0)
    @Published private(set) var estimatedProgress: Double = 0.0

    /// Increment to request a UI-only flash highlight (e.g. from a keyboard shortcut).
    @Published private(set) var focusFlashToken: Int = 0

    private var cancellables = Set<AnyCancellable>()
    private var navigationDelegate: BrowserNavigationDelegate?
    private var webViewObservers: [NSKeyValueObservation] = []

    // Avoid flickering the loading indicator for very fast navigations.
    private let minLoadingIndicatorDuration: TimeInterval = 0.35
    private var loadingStartedAt: Date?
    private var loadingEndWorkItem: DispatchWorkItem?
    private var loadingGeneration: Int = 0

    private var faviconTask: Task<Void, Never>?
    private var lastFaviconURLString: String?

    var displayTitle: String {
        if !pageTitle.isEmpty {
            return pageTitle
        }
        if let url = currentURL {
            return url.host ?? url.absoluteString
        }
        return "Browser"
    }

    var displayIcon: String? {
        "globe"
    }

    var isDirty: Bool {
        false
    }

    init(workspaceId: UUID, initialURL: URL? = nil) {
        self.id = UUID()
        self.workspaceId = workspaceId

        // Configure web view
        let config = WKWebViewConfiguration()
        config.processPool = BrowserPanel.sharedProcessPool
        // Ensure browser cookies/storage persist across navigations and launches.
        // This reduces repeated consent/bot-challenge flows on sites like Google.
        config.websiteDataStore = .default()

        // Enable developer extras (DevTools)
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Enable JavaScript
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Set up web view
        let webView = CmuxWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // Always present as Safari.
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent

        self.webView = webView

        // Set up navigation delegate
        let navDelegate = BrowserNavigationDelegate()
        navDelegate.didFinish = { webView in
            BrowserHistoryStore.shared.recordVisit(url: webView.url, title: webView.title)
            Task { @MainActor [weak self] in
                self?.refreshFavicon(from: webView)
            }
        }
        webView.navigationDelegate = navDelegate
        self.navigationDelegate = navDelegate

        // Observe web view properties
        setupObservers()

        // Navigate to initial URL if provided
        if let url = initialURL {
            navigate(to: url)
        }
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func triggerFlash() {
        focusFlashToken &+= 1
    }

    private func setupObservers() {
        // URL changes
        let urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.currentURL = webView.url
            }
        }
        webViewObservers.append(urlObserver)

        // Title changes
        let titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                // Keep showing the last non-empty title while the new navigation is loading.
                // WebKit often clears title to nil/"" during reload/navigation, which causes
                // a distracting tab-title flash (e.g. to host/URL). Only accept non-empty titles.
                let trimmed = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self?.pageTitle = trimmed
            }
        }
        webViewObservers.append(titleObserver)

        // Loading state
        let loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.handleWebViewLoadingChanged(webView.isLoading)
            }
        }
        webViewObservers.append(loadingObserver)

        // Can go back
        let backObserver = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.canGoBack = webView.canGoBack
            }
        }
        webViewObservers.append(backObserver)

        // Can go forward
        let forwardObserver = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.canGoForward = webView.canGoForward
            }
        }
        webViewObservers.append(forwardObserver)

        // Progress
        let progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor in
                self?.estimatedProgress = webView.estimatedProgress
            }
        }
        webViewObservers.append(progressObserver)
    }

    // MARK: - Panel Protocol

    func focus() {
        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }

        // If nothing meaningful is loaded yet, prefer letting the omnibar take focus.
        if !webView.isLoading {
            let urlString = webView.url?.absoluteString ?? currentURL?.absoluteString
            if urlString == nil || urlString == "about:blank" {
                return
            }
        }

        if Self.responderChainContains(window.firstResponder, target: webView) {
            return
        }
        window.makeFirstResponder(webView)
    }

    func unfocus() {
        guard let window = webView.window else { return }
        if Self.responderChainContains(window.firstResponder, target: webView) {
            window.makeFirstResponder(nil)
        }
    }

    func close() {
        // Ensure we don't keep a hidden WKWebView (or its content view) as first responder while
        // bonsplit/SwiftUI reshuffles views during close.
        unfocus()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        navigationDelegate = nil
        webViewObservers.removeAll()
        faviconTask?.cancel()
        faviconTask = nil
    }

    private func refreshFavicon(from webView: WKWebView) {
        faviconTask?.cancel()
        faviconTask = nil

        guard let pageURL = webView.url else { return }
        guard let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }

        faviconTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }

            // Try to discover the best icon URL from the document.
            let js = """
            (() => {
              const links = Array.from(document.querySelectorAll(
                'link[rel~=\"icon\"], link[rel=\"shortcut icon\"], link[rel=\"apple-touch-icon\"], link[rel=\"apple-touch-icon-precomposed\"]'
              ));
              function score(link) {
                const v = (link.sizes && link.sizes.value) ? link.sizes.value : '';
                if (v === 'any') return 1000;
                let max = 0;
                for (const part of v.split(/\\s+/)) {
                  const m = part.match(/(\\d+)x(\\d+)/);
                  if (!m) continue;
                  const a = parseInt(m[1], 10);
                  const b = parseInt(m[2], 10);
                  if (Number.isFinite(a)) max = Math.max(max, a);
                  if (Number.isFinite(b)) max = Math.max(max, b);
                }
                return max;
              }
              links.sort((a, b) => score(b) - score(a));
              return links[0]?.href || '';
            })();
            """

            var discoveredURL: URL?
            if let href = try? await webView.evaluateJavaScript(js) as? String {
                let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let u = URL(string: trimmed) {
                    discoveredURL = u
                }
            }

            let fallbackURL = URL(string: "/favicon.ico", relativeTo: pageURL)
            let iconURL = discoveredURL ?? fallbackURL
            guard let iconURL else { return }

            // Avoid repeated fetches.
            let iconURLString = iconURL.absoluteString
            if iconURLString == lastFaviconURLString, faviconPNGData != nil {
                return
            }
            lastFaviconURLString = iconURLString

            var req = URLRequest(url: iconURL)
            req.timeoutInterval = 2.0
            req.cachePolicy = .returnCacheDataElseLoad
            req.setValue(BrowserUserAgentSettings.safariUserAgent, forHTTPHeaderField: "User-Agent")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: req)
            } catch {
                return
            }

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return
            }

            // Use >= 2x the rendered point size so we don't upscale (blurry) on Retina.
            guard let png = Self.makeFaviconPNGData(from: data, targetPx: 32) else { return }
            // Only update if we got a real icon; keep the old one otherwise to avoid flashes.
            faviconPNGData = png
        }
    }

    @MainActor
    private static func makeFaviconPNGData(from raw: Data, targetPx: Int) -> Data? {
        guard let image = NSImage(data: raw) else { return nil }

        let px = max(16, min(128, targetPx))
        let size = NSSize(width: px, height: px)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        ctx?.imageInterpolation = .high
        ctx?.shouldAntialias = true
        NSGraphicsContext.current = ctx

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Aspect-fit into the target square.
        let srcSize = image.size
        let scale = min(size.width / max(1, srcSize.width), size.height / max(1, srcSize.height))
        let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
        let drawOrigin = NSPoint(x: (size.width - drawSize.width) / 2.0, y: (size.height - drawSize.height) / 2.0)
        // Align to integral pixels to avoid soft edges at small sizes.
        let drawRect = NSRect(
            x: round(drawOrigin.x),
            y: round(drawOrigin.y),
            width: round(drawSize.width),
            height: round(drawSize.height)
        )

        image.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: srcSize),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        return rep.representation(using: .png, properties: [:])
    }

    private func handleWebViewLoadingChanged(_ newValue: Bool) {
        if newValue {
            loadingGeneration &+= 1
            loadingEndWorkItem?.cancel()
            loadingEndWorkItem = nil
            loadingStartedAt = Date()
            isLoading = true
            return
        }

        let genAtEnd = loadingGeneration
        let startedAt = loadingStartedAt ?? Date()
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = max(0, minLoadingIndicatorDuration - elapsed)

        loadingEndWorkItem?.cancel()
        loadingEndWorkItem = nil

        if remaining <= 0.0001 {
            isLoading = false
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // If loading restarted, ignore this end.
            guard self.loadingGeneration == genAtEnd else { return }
            // If WebKit is still loading, ignore.
            guard !self.webView.isLoading else { return }
            self.isLoading = false
        }
        loadingEndWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    // MARK: - Navigation

    /// Navigate to a URL
    func navigate(to url: URL) {
        // Some installs can end up with a legacy Chrome UA override; keep this pinned.
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        var request = URLRequest(url: url)
        // Behave like a normal browser (respect HTTP caching). Reload is handled separately.
        request.cachePolicy = .useProtocolCachePolicy
        webView.load(request)
    }

    /// Navigate with smart URL/search detection
    /// - If input looks like a URL, navigate to it
    /// - Otherwise, perform a web search
    func navigateSmart(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = parseSmartInput(trimmed) {
            navigate(to: url)
        }
    }

    private func parseSmartInput(_ input: String) -> URL? {
        // Check if it's already a valid URL with scheme
        if let url = URL(string: input), url.scheme != nil {
            return url
        }

        // Check for localhost (prefer http:// since https is often not configured)
        if input.hasPrefix("localhost") || input.hasPrefix("127.0.0.1") {
            if let url = URL(string: "http://\(input)") {
                return url
            }
        }

        // Check if it looks like a domain (contains a dot and no spaces)
        if input.contains(".") && !input.contains(" ") {
            // Try adding https://
            if let url = URL(string: "https://\(input)") {
                return url
            }
        }

        // Treat as a search query
        let engine = BrowserSearchSettings.currentSearchEngine()
        return engine.searchURL(query: input)
    }

    /// Go back in history
    func goBack() {
        guard canGoBack else { return }
        webView.goBack()
    }

    /// Go forward in history
    func goForward() {
        guard canGoForward else { return }
        webView.goForward()
    }

    /// Reload the current page
    func reload() {
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        webView.reload()
    }

    /// Stop loading
    func stopLoading() {
        webView.stopLoading()
    }

    /// Take a snapshot of the web view
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, error in
            if let error = error {
                NSLog("BrowserPanel snapshot error: %@", error.localizedDescription)
                completion(nil)
                return
            }
            completion(image)
        }
    }

    /// Execute JavaScript
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    func suppressOmnibarAutofocus(for seconds: TimeInterval) {
        suppressOmnibarAutofocusUntil = Date().addingTimeInterval(seconds)
    }

    func shouldSuppressOmnibarAutofocus() -> Bool {
        if let until = suppressOmnibarAutofocusUntil {
            return Date() < until
        }
        return false
    }

    deinit {
        webViewObservers.removeAll()
    }
}

private extension BrowserPanel {
    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }
}

// MARK: - Navigation Delegate

private class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    var didFinish: ((WKWebView) -> Void)?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Navigation started
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish?(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("BrowserPanel navigation failed: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("BrowserPanel provisional navigation failed: %@", error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Allow all navigation for now
        decisionHandler(.allow)
    }
}
