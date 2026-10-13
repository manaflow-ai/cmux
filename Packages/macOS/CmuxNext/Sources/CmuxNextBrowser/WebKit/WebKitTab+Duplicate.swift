public import Foundation
public import WebKit

/// What a duplicate tab starts from: the original's history and scroll
/// (`interactionState`), its top-origin sessionStorage, and its URL.
public struct WebKitDuplicateSeed: Sendable {
    public var state: BrowserRestoreState
    var session: DuplicateSessionSeed?
    public var url: URL?
}

extension WebKitTab {
    /// The seed for a duplicate of this tab, or nil when WebKit has no
    /// history to save. Cookies, localStorage and service workers need no
    /// copy: the duplicate uses the same website data store. Form values of
    /// the current entry are not carried (WebKit saves them only when the
    /// document is destroyed).
    public func duplicateSeed() async -> WebKitDuplicateSeed? {
        guard let state = hibernationState() else { return nil }
        let world = WKContentWorld.world(name: DuplicateSessionSeed.worldName)
        var session: DuplicateSessionSeed?
        if let origin = webView.url.flatMap(PageInfoSite.origin(of:)),
           let json = try? await webView.evaluateJavaScript(
               "JSON.stringify(Object.fromEntries(Object.entries(sessionStorage)))", in: nil, contentWorld: world
           ) as? String,
           let items = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] {
            session = DuplicateSessionSeed(origin: origin, items: items)
        }
        return WebKitDuplicateSeed(state: state, session: session, url: webView.url)
    }

    /// Makes this fresh tab a duplicate: seeds sessionStorage for the first
    /// document only, then restores the history with the POST guard; a
    /// restored form submission is cancelled and the original's URL loads
    /// by GET instead.
    @discardableResult
    public func applyDuplicate(_ seed: WebKitDuplicateSeed, fallback: URL? = nil) -> Bool {
        if let source = seed.session?.scriptSource, !source.isEmpty {
            webView.configuration.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                in: WKContentWorld.world(name: DuplicateSessionSeed.worldName)
            ))
            seedInstalled = true
        }
        return restore(seed.state, fallback: fallback ?? seed.url)
    }

    /// The restore reached its first document (or was cancelled): the guard
    /// ends, and a duplicate's seed is removed. WKUserContentController has
    /// no per-script removal, so the standing scripts are added again.
    func finishRestore() {
        restoringHistory = false
        guard seedInstalled else { return }
        seedInstalled = false
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        installStandingScripts(controller)
    }
}
