public import AppKit
import CmuxNextDesign
public import CmuxNextSettings
public import WebKit

/// Holds the pooled view for its scheme handler, which is made before the view exists.
final class PageServedOwner {
    weak var view: PageWebView?
}

/// A pooled host changes page (plans/cmux-next/react-pages.md "Page shell", ``PageHostPool``).
extension PageWebView {
    /// The user scripts every page document starts with: the theme bootstrap, then its attributes.
    static func installUserScripts(_ controller: WKUserContentController, documentAttributes: [String: String]) {
        controller.removeAllUserScripts()
        controller.addUserScript(
            WKUserScript(source: WebTheme.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        if let script = attributesScript(documentAttributes) {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        controller.addUserScript(PagePaintProbe.userScript)
    }

    /// What this pooled view's scheme handler serves for `host` (``PageServedHosts``).
    func servedHost(_ host: String) -> PageSchemeHandler.Served? {
        PageServedHosts.served(host: host, current: servedDescriptor.serving(descriptor), dynamicSource: dynamicResources)
    }

    /// Whether `descriptor` mounts in the shell this view shows now (a claim, no navigation).
    func claimsInShell(_ descriptor: PageDescriptor) -> Bool {
        descriptor.inShell && servedDescriptor.id == PageDescriptor.shell.id
    }

    /// Shows `descriptor` in this pooled host. A shell page while the shell is shown is a claim:
    /// no navigation; the router serves the page's namespaces and native ops, its dynamic resources
    /// are served under the shell origin, and trust still checks the shell origin. Any other page
    /// is a full main-frame navigation to its own origin (a shell page with the shell not shown
    /// navigates to the shell). Either way the old page's subscriptions end and its pending host
    /// calls fail with `cmux.protocol.closed` before the new descriptor admits anything, the
    /// registry finds the view under the new id, and the previous document attributes, theme
    /// surface and route are dropped. False for a view that is not pooled.
    @discardableResult
    public func retarget(descriptor: PageDescriptor, routes: [PageRoute],
                         dynamicResources: (any PageDynamicResourceSource)? = nil, route: String? = nil) -> Bool {
        guard isPooled, PageID.isFirstParty(descriptor.id) else { return false }
        // A swap inside a claim: the old shell page is reset first (router unbound, then `page.reset`).
        if claimsInShell(descriptor), self.descriptor.id != servedDescriptor.id { resetShellPage() }
        router.bind(descriptor, routes: routes)
        self.dynamicResources = dynamicResources
        self.descriptor = descriptor
        setAccessibilityIdentifier("cmux.page.\(descriptor.id)")
        Self.installUserScripts(webView.configuration.userContentController, documentAttributes: [:])
        // The new page has not painted: a navigation's document-end probe, or the shell's message
        // after it mounts the claimed page, sets it again.
        paintedUptime = nil
        themeSurface = nil
        self.route = route.map { $0.hasPrefix("#") ? $0 : "#" + $0 }
        if claimsInShell(descriptor) { return true }
        let served = descriptor.inShell ? PageDescriptor.shell : descriptor
        servedDescriptor = served
        loaded = false
        webView.load(URLRequest(url: served.url(route: descriptor.inShell ? nil : route)))
        return true
    }

    /// Mounts the bound shell page: sends `page.claim {page, route, context}` in this main-actor
    /// turn (the shell mounts it synchronously when the page's chunk is loaded). `reply` gets the
    /// shell's answer.
    /// `prepare` mounts the page ahead of its claim (no context; ``sendResume(routes:route:context:reply:)`` hands
    /// it the session later).
    public func sendClaim(context: JSONValue = .null, prepare: Bool = false,
                          reply: ((Result<JSONValue, PageError>) -> Void)? = nil) {
        var params: [String: JSONValue] = ["page": .string(descriptor.id), "route": .string(route ?? ""), "context": context]
        if prepare { params["prepare"] = .bool(true) }
        paintedUptime = nil
        router.sendCall(PageShellOp.claim, params: .object(params)) { reply?($0) }
    }

    /// Ends the claimed shell page: the router admits nothing first (a late call from the old page
    /// gets `unknown_op`), then the shell unmounts it, ends its calls and streams and clears every
    /// store and global it could have written. The view then serves the bare shell.
    public func resetShellPage(reply: ((Result<JSONValue, PageError>) -> Void)? = nil) {
        router.unbind()
        paintedUptime = nil
        dynamicResources = nil
        descriptor = servedDescriptor
        setAccessibilityIdentifier("cmux.page.\(descriptor.id)")
        themeSurface = nil
        route = nil
        router.sendCall(PageShellOp.reset, params: [:]) { reply?($0) }
    }

    /// Waits until the shell booted (its module can run after the load finished), then loads
    /// every shell page chunk (`cmuxShell.preload()`), so a claim mounts in the same turn. True
    /// when the shell is ready. A host-run script, not a page op: it does not touch the host.
    func preloadShellPages() async -> Bool {
        guard servedDescriptor.id == PageDescriptor.shell.id else { return false }
        let script = """
        if (!globalThis.cmuxShell) {
          await Promise.race([
            new Promise((resolve) => { globalThis.__cmuxShellOnBoot = resolve; }),
            new Promise((resolve) => setTimeout(resolve, 10000)),
          ]);
        }
        if (!globalThis.cmuxShell) return false;
        await globalThis.cmuxShell.preload();
        return true;
        """
        return (try? await webView.callAsyncJavaScript(script, contentWorld: .page)) as? Bool == true
    }

    /// Whether the document finished loading (its first `didFinish`).
    public var isLoaded: Bool { loaded }

    /// Returns when the document has finished loading (at once when it has), failed to load, or
    /// the view closed; ``isLoaded`` tells which.
    public func waitUntilLoaded() async {
        guard !loaded else { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }
}

/// The page shell's host calls (webviews/src/pages/shell/shell.ts `ShellOps`).
public nonisolated struct PageShellOp {
    public nonisolated init() {}
    public static let claim = "page.claim"
    public static let reset = "page.reset"
    public static let resume = "page.resume"
}
