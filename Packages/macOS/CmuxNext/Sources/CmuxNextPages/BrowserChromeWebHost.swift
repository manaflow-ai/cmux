public import AppKit
public import CmuxNextBrowserCore
import CmuxNextSettings

/// The browser chrome's React surfaces (``BrowserChromeWebContent``): a transparent WebKit page
/// inside the chrome's own glass. The owner's state goes to the page on `cmux.<page>.state`; the
/// page's `cmux.<page>.command` and `cmux.<page>.size` calls go back to the owner.
@MainActor
public final class BrowserChromeWebHost: BrowserChromeWebContent {
    /// The bubble's page floats in a glass panel that closes when it loses the keys, and the Page
    /// Info windows' pages draw over their window's surface; a Chromium page is an opaque child
    /// window that takes the keys.
    static let engineOptions = PageEngineOptions(requiresWebKit: .transparentOverlay)

    let page: PageWebView
    private let provider: BrowserChromeWebProvider
    public var onMessage: ((String, [String: Any]) -> Void)? {
        get { provider.onMessage }
        set { provider.onMessage = newValue }
    }

    public var view: NSView { page }

    public init?(_ surface: BrowserChromeWebPage) {
        let descriptor: PageDescriptor
        switch surface {
        case .pageInfo: descriptor = .pageInfo
        case .siteSettings: descriptor = .siteSettings
        case .siteData: descriptor = .siteData
        case .certificate: descriptor = .certificate
        }
        let provider = BrowserChromeWebProvider(namespace: descriptor.id + ".")
        guard let page = PageWebView(descriptor: descriptor, routes: [PageRoute(prefix: provider.namespace, provider: provider)],
                                     options: Self.engineOptions) else { return nil }
        // The owner sizes the card in points from the page's reports and pushes its metrics in
        // points: one CSS pixel is one point.
        page.followsUIScale = false
        self.page = page
        self.provider = provider
    }

    public func push(_ state: [String: Any]) {
        provider.push(JSONValue(foundation: state) ?? .null)
    }

    public func focus() {
        page.focusPage()
    }

    public func close() {
        provider.onMessage = nil
        page.removeFromSuperview()
        page.close()
    }
}

/// The page side of one surface: keeps the owner's last state, so a page that subscribes after
/// a push (its first load, a reload) draws it at once.
@MainActor
final class BrowserChromeWebProvider: PageProvider {
    let namespace: String
    var onMessage: ((String, [String: Any]) -> Void)?
    private var state: JSONValue?
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]

    init(namespace: String) {
        self.namespace = namespace
    }

    public func push(_ next: JSONValue) {
        state = next
        for listener in listeners.values { listener(next) }
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op.hasPrefix(namespace) else { throw PageError.unknownOp(op) }
        let kind = String(op.dropFirst(namespace.count))
        guard kind == "command" || kind == "size" else { throw PageError.unknownOp(op) }
        onMessage?(kind, params.foundationObject as? [String: Any] ?? [:])
        return .object([:])
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == namespace + "state" else { throw PageError.unknownOp(stream) }
        let id = UUID()
        listeners[id] = onEvent
        if let state { onEvent(state) }
        return PageSubscription { [weak self] in self?.listeners[id] = nil }
    }
}
