#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// The Feed's markdown renderer (PLAN, SPEC 8.2): full GFM + TeX in a
/// non-scrolling `WKWebView`. To keep scrolling smooth:
/// - one shared `WKProcessPool` and configuration family for every view;
/// - a pool of web views prewarmed with the template (scripts parsed once per
///   view), reused across cells: new content is a JS call, never a page load;
/// - heights measured in JS (sync on render, then `ResizeObserver`) and cached
///   by (content, style, width), and prefetched off screen so cells are sized
///   before they appear and never jump.
@MainActor
public final class WebMarkdownRenderer {
    public static let shared = WebMarkdownRenderer()

    public enum Style: String, Sendable {
        /// Body 17, line pitch ~27 (Feed cells, transcript math).
        case body
        /// Subheadline (compact previews).
        case compact
    }

    /// WKProcessPool is a no-op since iOS 15 (one process per app), kept so the
    /// "share one pool" requirement still holds on any WebKit that honours it.
    let processPool = WKProcessPool()
    private var idle: [PooledWebView] = []
    private var heights: [HeightKey: CGFloat] = [:]
    private let maxIdle = 12
    private var measurer: PooledWebView?
    private var measureQueue: [(String, Style, CGFloat)] = []
    private var measuring = false
    /// Notifies cells whose height arrived from the prefetcher.
    public private(set) var heightRevision = 0
    /// The last column width a web markdown view laid out at; new views start
    /// from it so their first layout already uses the cached height.
    public var lastWidth: CGFloat = 0

    /// Cached height at the last known width (cells read it before their first layout).
    public func cachedHeight(markdown: String, style: Style) -> CGFloat? {
        cachedHeight(markdown: markdown, style: style, width: lastWidth)
    }

    struct HeightKey: Hashable {
        let content: Int
        let style: Style
        let width: Int
        /// Heights depend on the text size: a Dynamic Type change misses every cached height.
        let textSize: String
    }

    /// The current Dynamic Type size, part of every height key.
    static var textSizeKey: String {
        UIApplication.shared.preferredContentSizeCategory.rawValue
    }

    static var resourceDirectory: URL? {
        Bundle.module.url(forResource: "web", withExtension: nil)
    }

    /// Creates `count` ready web views so the first Feed screen does not pay page loads.
    public func prewarm(count: Int = 6) {
        let missing = max(0, count - idle.count)
        for _ in 0..<missing {
            idle.append(PooledWebView(renderer: self))
        }
    }

    func dequeue() -> PooledWebView {
        if let view = idle.popLast() { return view }
        return PooledWebView(renderer: self)
    }

    func enqueue(_ view: PooledWebView) {
        view.reset()
        view.removeFromSuperview()
        if idle.count < maxIdle { idle.append(view) }
    }

    public func cachedHeight(markdown: String, style: Style, width: CGFloat) -> CGFloat? {
        heights[HeightKey(content: markdown.hashValue, style: style, width: Int(width.rounded()), textSize: Self.textSizeKey)]
    }

    func store(height: CGFloat, markdown: String, style: Style, width: CGFloat) {
        let key = HeightKey(content: markdown.hashValue, style: style, width: Int(width.rounded()), textSize: Self.textSizeKey)
        if heights[key] != height {
            heights[key] = height
        }
    }

    /// Measures heights off screen ahead of display (Feed calls it with upcoming events).
    public func prefetchHeights(_ markdowns: [String], style: Style, width: CGFloat) {
        guard width > 0 else { return }
        for markdown in markdowns where cachedHeight(markdown: markdown, style: style, width: width) == nil {
            measureQueue.append((markdown, style, width))
        }
        pumpMeasure()
    }

    private func pumpMeasure() {
        guard !measuring, !measureQueue.isEmpty else { return }
        let measurer = measurer ?? PooledWebView(renderer: self)
        self.measurer = measurer
        let (markdown, style, width) = measureQueue.removeFirst()
        if cachedHeight(markdown: markdown, style: style, width: width) != nil {
            pumpMeasure()
            return
        }
        measuring = true
        measurer.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        measurer.render(markdown: markdown, style: style) { [weak self] height in
            guard let self else { return }
            self.measuring = false
            if let height {
                self.store(height: height, markdown: markdown, style: style, width: width)
                self.heightRevision &+= 1
            }
            self.pumpMeasure()
        }
    }
}

/// One reusable web view. Holds the template, routes height messages to the current owner.
@MainActor
final class PooledWebView: UIView, WKNavigationDelegate {
    let webView: WKWebView
    private var isReady = false
    private var pending: (() -> Void)?
    var onHeight: ((CGFloat) -> Void)?
    /// Set when the host wants taps (and side-scrolling code and tables); nil keeps the
    /// web view inert so the cell's own gestures win.
    var onTap: (() -> Void)? {
        didSet {
            let interactive = onTap != nil
            webView.isUserInteractionEnabled = interactive
            isUserInteractionEnabled = interactive
        }
    }
    private(set) var renderedKey: String?

    init(renderer: WebMarkdownRenderer) {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = renderer.processPool
        configuration.suppressesIncrementalRendering = false
        configuration.dataDetectorTypes = []
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 100), configuration: configuration)
        super.init(frame: .zero)
        controller.add(MessageProxy(owner: self), name: "cmuxMobile")
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = self
        clipsToBounds = true
        isUserInteractionEnabled = false
        addSubview(webView)
        if let directory = WebMarkdownRenderer.resourceDirectory {
            webView.loadFileURL(directory.appendingPathComponent("template.html"), allowingReadAccessTo: directory)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The web view keeps its full content height; the container clips (Show more animates the clip).
    var contentHeight: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = max(contentHeight, bounds.height, 1)
        if webView.frame.size != CGSize(width: bounds.width, height: height) {
            webView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        }
    }

    func handle(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            let work = pending
            pending = nil
            work?()
        case "tap":
            onTap?()
        case "height":
            if let value = message["height"] as? Double {
                onHeight?(CGFloat(value))
            }
        default:
            break
        }
    }

    func render(markdown: String, style: WebMarkdownRenderer.Style, completion: ((CGFloat?) -> Void)? = nil) {
        let key = Self.key(markdown: markdown, style: style)
        renderedKey = key
        // A recycled view still shows its previous body until the new one paints: hide it until then.
        webView.alpha = 0
        let work = { [weak self] in
            guard let self else { return }
            let json = (try? JSONEncoder().encode([markdown])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            let script = "cmuxMobileRender(\(json)[0], \(style == .compact))"
            self.webView.evaluateJavaScript(script) { result, _ in
                let height = (result as? Double).map { CGFloat($0) } ?? (result as? Int).map { CGFloat($0) }
                MainActor.assumeIsolated {
                    if self.renderedKey == key { self.webView.alpha = 1 }
                    completion?(height)
                }
            }
        }
        if isReady { work() } else { pending = work }
    }

    func reset() {
        onHeight = nil
        onTap = nil
        renderedKey = nil
        contentHeight = 0
        // No clearing render: the next `render` hides the view until its own
        // content paints, and a JavaScript call per recycled cell cost the
        // scroll a round trip to the web process.
    }

    /// What the view shows: content, style and the text size it laid out at.
    static func key(markdown: String, style: WebMarkdownRenderer.Style) -> String {
        "\(style.rawValue)\u{0}\(WebMarkdownRenderer.textSizeKey)\u{0}\(markdown)"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        webView.reload()
    }

    /// A tapped link never navigates the pooled view (it left the template
    /// and the cell blank). A web link opens in Safari; a file link opens the
    /// event, whose chat previews the file.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        // An in-page anchor stays put.
        if url.fragment != nil, url.path == webView.url?.path, url.scheme == webView.url?.scheme { return }
        if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel", "sms", "facetime"].contains(scheme) {
            UIApplication.shared.open(url)
        } else {
            onTap?()
        }
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: PooledWebView?

    init(owner: PooledWebView) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            owner?.handle(message.body)
        }
    }
}

/// SwiftUI host. `collapsedHeight` caps the visible height; `isExpanded`
/// lifts the cap (the frame change animates; the web view never re-lays out).
public struct WebMarkdownView: View {
    let markdown: String
    let style: WebMarkdownRenderer.Style
    var collapsedHeight: CGFloat?
    var isExpanded: Bool
    var onContentHeight: ((CGFloat) -> Void)?
    var onTap: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var measured: CGFloat?
    @State private var width: CGFloat = WebMarkdownRenderer.shared.lastWidth

    public init(
        markdown: String, style: WebMarkdownRenderer.Style = .body, collapsedHeight: CGFloat? = nil,
        isExpanded: Bool = false, onTap: (() -> Void)? = nil, onContentHeight: ((CGFloat) -> Void)? = nil
    ) {
        self.onTap = onTap
        self.markdown = markdown
        self.style = style
        self.collapsedHeight = collapsedHeight
        self.isExpanded = isExpanded
        self.onContentHeight = onContentHeight
    }

    private var contentHeight: CGFloat {
        measured ?? WebMarkdownRenderer.shared.cachedHeight(markdown: markdown, style: style, width: width) ?? estimate
    }

    private var estimate: CGFloat {
        let chars = CGFloat(markdown.count)
        let perLine = max(width / 9, 30)
        return min(max(27, (chars / perLine).rounded(.up) * 27 + CGFloat(markdown.filter { $0 == "\n" }.count) * 6), 2000)
    }

    public var body: some View {
        let full = contentHeight
        let shown = (collapsedHeight.map { isExpanded ? full : min(full, $0) }) ?? full
        WebMarkdownRepresentable(markdown: markdown, style: style, contentHeight: full, textSize: dynamicTypeSize, onTap: onTap) { height in
            guard measured != height else { return }
            WebMarkdownRenderer.shared.store(height: height, markdown: markdown, style: style, width: width)
            measured = height
            onContentHeight?(height)
        }
        .frame(height: shown, alignment: .top)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            if newWidth > 0 { WebMarkdownRenderer.shared.lastWidth = newWidth }
            if abs(newWidth - width) > 0.5 {
                width = newWidth
                measured = WebMarkdownRenderer.shared.cachedHeight(markdown: markdown, style: style, width: newWidth)
                if let measured { onContentHeight?(measured) }
            }
        }
        // Streaming text changes every tick: keep the last measured height until the new
        // one arrives (a cached one if known) instead of an estimate, so no blank gap opens.
        .onChange(of: markdown) {
            if let cached = WebMarkdownRenderer.shared.cachedHeight(markdown: markdown, style: style, width: width) {
                measured = cached
            }
        }
        // A Dynamic Type change re-renders at the new size; hold the old height until the
        // new one is known instead of falling back to an estimate.
        .onChange(of: dynamicTypeSize) {
            if let cached = WebMarkdownRenderer.shared.cachedHeight(markdown: markdown, style: style, width: width) {
                measured = cached
                onContentHeight?(cached)
            }
        }
        .onAppear { if let cached = WebMarkdownRenderer.shared.cachedHeight(markdown: markdown, style: style, width: width) { onContentHeight?(cached) } }
        .accessibilityElement()
        .accessibilityLabel(Text(markdown))
    }
}

struct WebMarkdownRepresentable: UIViewRepresentable {
    let markdown: String
    let style: WebMarkdownRenderer.Style
    let contentHeight: CGFloat
    var textSize: DynamicTypeSize = .large
    var onTap: (() -> Void)?
    let onHeight: (CGFloat) -> Void

    func makeUIView(context: Context) -> PooledWebView {
        let view = WebMarkdownRenderer.shared.dequeue()
        view.onHeight = onHeight
        view.onTap = onTap
        view.contentHeight = contentHeight
        view.render(markdown: markdown, style: style)
        return view
    }

    func updateUIView(_ view: PooledWebView, context: Context) {
        view.onHeight = onHeight
        view.contentHeight = contentHeight
        view.onTap = onTap
        let key = PooledWebView.key(markdown: markdown, style: style)
        if view.renderedKey != key {
            view.render(markdown: markdown, style: style)
        }
    }

    static func dismantleUIView(_ view: PooledWebView, coordinator: ()) {
        WebMarkdownRenderer.shared.enqueue(view)
    }
}
#endif
