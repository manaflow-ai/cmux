public import CmuxFoundation
public import SwiftUI
public import WebKit

/// How much of the sidebar is covered by the host's floating chrome.
///
/// The window's titlebar controls float *over* the top of the sidebar and the footer floats over the
/// bottom, so a page that fills the sidebar rect edge to edge has its first and last rows sitting
/// underneath them. Only the host knows these heights — they derive from the titlebar metric and can
/// change between releases — so they are passed in rather than guessed at here.
public struct CustomSidebarWebInsets: Equatable, Sendable {
    public var top: CGFloat
    public var bottom: CGFloat

    public init(top: CGFloat, bottom: CGFloat) {
        self.top = top
        self.bottom = bottom
    }

    public static let zero = CustomSidebarWebInsets(top: 0, bottom: 0)
}

/// Hosts a web-backed custom sidebar.
///
/// Deliberately chrome-less: no omnibar, no tab bar, no navigation controls. The page *is* the
/// sidebar, so any chrome above it is taken directly out of the sidebar's usable height — which is
/// the reason to host on the left at all rather than opening a browser pane in the Dock.
///
/// ## Chrome insets
///
/// Two modes, following the same contract browsers use for display cutouts:
///
/// - **Default.** The web view is laid out inside the safe region, so the page's viewport *is* the
///   usable area. An author writes ordinary HTML — `height: 100vh` included — and never learns that
///   cmux has a floating titlebar. Getting this wrong is invisible until someone's first row is
///   behind the traffic lights, so the safe behaviour is the one you get for free.
/// - **`viewport-fit=cover`.** The page declares it will handle insets itself, gets the full sidebar
///   rect, and reads `--cmux-sidebar-inset-top` / `--cmux-sidebar-inset-bottom`. This is what lets a
///   sidebar scroll its rows *under* the translucent chrome the way the native workspace rail does.
///
/// The custom properties exist because macOS `WKWebView` does not plumb `NSView.safeAreaInsets`
/// through to CSS `env(safe-area-inset-*)`: with insets set on the view, `env()` still resolves to
/// `0px` in every direction (verified on macOS 26). On iOS `env()` would have been the natural
/// channel; here the values have to be injected.
public struct CustomSidebarWebView: NSViewRepresentable {
    private let source: CustomSidebarWebSource
    private let insets: CustomSidebarWebInsets
    private let reloadToken: CustomSidebarWebReloadToken
    private let focusWorkspace: (@MainActor (UUID) -> CustomSidebarFocusStatus)?
    private let requestInputFocus: (@MainActor (NSWindow) -> Void)?

    /// Creates the hosted sidebar.
    ///
    /// - Parameters:
    ///   - source: The page to render.
    ///   - insets: How much of the sidebar the host's floating chrome covers.
    ///   - reloadToken: Bumped by the host to force a re-fetch. Needed because `cmux sidebar
    ///     reload` asks for exactly the case the source-changed check ignores: the same page, read
    ///     again.
    ///   - focusWorkspace: Selects a workspace on the page's behalf and reports what happened.
    ///     Supplying it offers the focus bridge; whether the bridge is actually registered still
    ///     depends on the source arming a ``CustomSidebarFocusScope``, so a public page cannot get
    ///     it by being passed a handler. Omit it to host a page with no native reach at all.
    ///   - requestInputFocus: Records that this sidebar now owns the host window's keyboard focus.
    ///     The web view itself becomes first responder immediately after this callback.
    public init(
        source: CustomSidebarWebSource,
        insets: CustomSidebarWebInsets = .zero,
        reloadToken: CustomSidebarWebReloadToken = .initial,
        focusWorkspace: (@MainActor (UUID) -> CustomSidebarFocusStatus)? = nil,
        requestInputFocus: (@MainActor (NSWindow) -> Void)? = nil
    ) {
        self.source = source
        self.insets = insets
        self.reloadToken = reloadToken
        self.focusWorkspace = focusWorkspace
        self.requestInputFocus = requestInputFocus
    }

    public func makeNSView(context: Context) -> CustomSidebarWebContainerView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            context.coordinator,
            name: CustomSidebarWebView.viewportMessageName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.bootstrapScript(insets: insets),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = CustomSidebarInputWebView(frame: .zero, configuration: configuration)
        webView.onRequestInputFocus = requestInputFocus
        // The page paints its own background. Letting the web view draw one flashes white on every
        // load, which is jarring against the sidebar's chrome in dark mode.
        webView.setValue(false, forKey: "drawsBackground")
        // A sidebar is not a browser: swiping should not navigate away from the page, leaving the
        // user on a blank view with no visible way back.
        webView.allowsBackForwardNavigationGestures = false

        let container = CustomSidebarWebContainerView(webView: webView)
        container.insets = insets
        context.coordinator.container = container
        context.coordinator.attach(
            registry: CustomSidebarWebViewFocusHandlerRegistry(
                userContentController: configuration.userContentController
            ),
            webView: webView
        )
        context.coordinator.apply(
            source: source,
            reloadToken: reloadToken,
            focusWorkspace: focusWorkspace,
            into: webView
        )
        return container
    }

    public func updateNSView(_ container: CustomSidebarWebContainerView, context: Context) {
        context.coordinator.container = container
        (container.webView as? CustomSidebarInputWebView)?.onRequestInputFocus = requestInputFocus
        if container.insets != insets {
            container.insets = insets
            // The page keeps rendering while the chrome resizes, so the variables are refreshed in
            // place rather than by reloading and losing scroll position.
            container.webView.evaluateJavaScript(
                "window.__cmuxSidebarSetInsets && window.__cmuxSidebarSetInsets(\(insets.top), \(insets.bottom))",
                completionHandler: nil
            )
        }
        context.coordinator.apply(
            source: source,
            reloadToken: reloadToken,
            focusWorkspace: focusWorkspace,
            into: container.webView
        )
    }

    public static func dismantleNSView(_ container: CustomSidebarWebContainerView, coordinator: Coordinator) {
        // The content controller retains its message handlers, so leaving these registered would
        // keep the coordinator (and through it the container) alive after the sidebar is swapped
        // away — and in the focus bridge's case would leave a native capability registered on a web
        // view nothing is watching any more.
        container.webView.configuration.userContentController.removeScriptMessageHandler(
            forName: CustomSidebarWebView.viewportMessageName
        )
        coordinator.releaseFocusBridge()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    fileprivate static let viewportMessageName = "cmuxSidebarViewport"

    /// Publishes the inset values and reports whether the page opted into full-bleed layout.
    ///
    /// The viewport `<meta>` has not been parsed at document-start, so the check waits for
    /// `DOMContentLoaded`; until it answers, the host stays in the safe default.
    private static func bootstrapScript(insets: CustomSidebarWebInsets) -> String {
        """
        (() => {
          const root = document.documentElement;
          window.__cmuxSidebarSetInsets = (top, bottom) => {
            root.style.setProperty('--cmux-sidebar-inset-top', top + 'px');
            root.style.setProperty('--cmux-sidebar-inset-bottom', bottom + 'px');
          };
          window.__cmuxSidebarSetInsets(\(insets.top), \(insets.bottom));

          const wantsCover = () => {
            const meta = document.querySelector('meta[name="viewport"]');
            return !!meta && /viewport-fit\\s*=\\s*cover/i.test(meta.getAttribute('content') || '');
          };
          const report = () => {
            window.webkit?.messageHandlers?.\(viewportMessageName)?.postMessage({ cover: wantsCover() });
          };
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', report, { once: true });
          } else {
            report();
          }
        })();
        """
    }

    /// MainActor-isolated because every `WKWebView` mutation it performs is, and the
    /// representable's make/update callbacks already run there.
    @MainActor
    public final class Coordinator: NSObject, WKScriptMessageHandler {
        private var loadedSource: CustomSidebarWebSource?
        private var loadedReloadToken = CustomSidebarWebReloadToken.initial
        /// Number of page loads actually issued.
        ///
        /// The decision not to reload is as load-bearing as the decision to reload — the sidebar
        /// updates about once a second — and `WKWebView.isLoading` cannot answer it: a load that was
        /// never issued and one that already finished look identical. Counting the issue point is
        /// the only place the distinction exists.
        private(set) var issuedLoadCount = 0
        /// The scope the current source armed, or `nil` when nothing is armed.
        ///
        /// Mirrors exactly what is registered: non-`nil` iff the focus handler and the navigation
        /// lock are installed.
        private(set) var armedScope: CustomSidebarFocusScope?
        private var registry: (any CustomSidebarFocusHandlerRegistering)?
        private var capability: CustomSidebarFocusCapability?
        private var focusBridge: CustomSidebarFocusBridge?
        private var navigationLock: CustomSidebarNavigationLock?
        private weak var lockedWebView: WKWebView?
        weak var container: CustomSidebarWebContainerView?

        /// Binds the coordinator to where the focus handler is registered.
        ///
        /// - Parameters:
        ///   - registry: Where the handler is installed and removed.
        ///   - webView: The web view whose navigation delegate the lock occupies.
        func attach(registry: any CustomSidebarFocusHandlerRegistering, webView: WKWebView) {
            self.registry = registry
            lockedWebView = webView
        }

        /// Applies a source and the host's current focus capability together.
        ///
        /// The two are reconciled on every update, not only when the source changes. A source change
        /// reloads the page; a capability that appeared or disappeared while the source stayed put
        /// still has to arm or disarm, because a host that stops offering the capability is
        /// withdrawing it now, not at whatever future moment the page happens to navigate.
        ///
        /// - Parameters:
        ///   - source: The page to render.
        ///   - reloadToken: Bumped by the host when a reload was explicitly requested.
        ///   - focusWorkspace: The host's current focus implementation, or `nil` when it offers none.
        ///   - webView: The sidebar's web view.
        func apply(
            source: CustomSidebarWebSource,
            reloadToken: CustomSidebarWebReloadToken = .initial,
            focusWorkspace: (@MainActor (UUID) -> CustomSidebarFocusStatus)?,
            into webView: WKWebView
        ) {
            reconcileFocusBridge(for: source, focusWorkspace: focusWorkspace, in: webView)
            load(source, reloadToken: reloadToken, into: webView)
        }

        /// Drops the bridge and the navigation lock when the sidebar is torn down.
        func releaseFocusBridge() {
            registry?.removeFocusHandler()
            lockedWebView?.navigationDelegate = nil
            armedScope = nil
            capability = nil
            focusBridge = nil
            navigationLock = nil
        }

        /// Loads when the source changed, or when a reload was explicitly requested.
        ///
        /// `updateNSView` runs on unrelated SwiftUI invalidations — and the custom sidebar is
        /// mounted inside a one-second `TimelineView` — so reloading on every update would discard
        /// the page's scroll position, filter text, and open menus roughly once a second. But an
        /// explicit `cmux sidebar reload` is precisely a request to re-fetch an unchanged source, so
        /// the token has to be able to force what the source check would otherwise skip.
        private func load(
            _ source: CustomSidebarWebSource,
            reloadToken: CustomSidebarWebReloadToken,
            into webView: WKWebView
        ) {
            let reloadRequested = loadedReloadToken != reloadToken
            loadedReloadToken = reloadToken
            guard loadedSource != source || reloadRequested else { return }
            loadedSource = source
            issuedLoadCount += 1
            // An explicit reload is a request for the server's *current* bytes. Left on the default
            // policy, a second load of the same URL is entitled to come back from the URL cache and
            // repaint the identical stale document — which, from the user's side, is
            // indistinguishable from the reload never having run.
            let cachePolicy: URLRequest.CachePolicy = reloadRequested
                ? .reloadIgnoringLocalCacheData
                : .useProtocolCachePolicy
            // A reload replaces the document, so any previous full-bleed opt-in no longer applies;
            // the incoming page re-declares it or gets the safe default.
            container?.isFullBleed = false
            switch source {
            case let .document(fileURL):
                // Read access is scoped to the document's own directory so a sidebar can pull in
                // sibling assets without being handed the rest of the filesystem.
                //
                // `loadFileURL` takes no cache policy; a local document is re-read from disk, and
                // its subresources are the case the author controls by filename anyway.
                webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            case let .remote(url):
                webView.load(URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: 60))
            }
        }

        /// Brings the registered handler in line with what the source and the host currently allow.
        ///
        /// Four transitions, all of which must be immediate:
        ///
        /// - Nothing armed, and it should be → install the handler and the lock.
        /// - Something armed that should not be (the source no longer qualifies, or the host stopped
        ///   offering the capability) → remove both.
        /// - Armed on a different scope → tear down and rebuild, so the lock pins the new source.
        /// - Armed on the same scope → keep the registration and swap the closure inside the
        ///   capability, so a fresh mount's closure is what the page reaches without the handler
        ///   ever being absent for a frame.
        private func reconcileFocusBridge(
            for source: CustomSidebarWebSource,
            focusWorkspace: (@MainActor (UUID) -> CustomSidebarFocusStatus)?,
            in webView: WKWebView
        ) {
            lockedWebView = webView
            let desiredScope = focusWorkspace == nil ? nil : CustomSidebarFocusScope(source: source)

            guard let desiredScope, let focusWorkspace else {
                guard armedScope != nil else { return }
                releaseFocusBridge()
                return
            }
            if armedScope == desiredScope, let capability {
                capability.focus = focusWorkspace
                return
            }

            releaseFocusBridge()
            let capability = CustomSidebarFocusCapability(focus: focusWorkspace)
            let bridge = CustomSidebarFocusBridge(scope: desiredScope, capability: capability)
            registry?.installFocusHandler(bridge)
            self.capability = capability
            focusBridge = bridge
            armedScope = desiredScope

            let lock = CustomSidebarNavigationLock(scope: desiredScope)
            // `navigationDelegate` is weak, so the lock is held here for as long as this source is
            // armed; letting it deallocate would silently unlock the frame.
            navigationLock = lock
            webView.navigationDelegate = lock
        }

        nonisolated public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // `viewport-fit=cover` is the *page* declaring it will handle the host's chrome itself,
            // and honouring it hands the page the strip under the traffic lights. The bootstrap
            // script is injected main-frame-only, but the handler is registered on the content
            // controller, which is page-wide — so an embedded frame can post the same body. A
            // sidebar embedding a third-party iframe is a supported design, and that frame does not
            // get to relayout the page hosting it.
            guard message.frameInfo.isMainFrame else { return }
            let body = message.body as? [String: Any]
            let cover = body?["cover"] as? Bool ?? false
            Task { @MainActor [weak self] in
                self?.container?.isFullBleed = cover
            }
        }
    }
}

/// Lays the web view out either inside the safe region or across the full sidebar rect.
///
/// A container is used rather than insetting the representable with `.padding` because the choice
/// depends on what the loaded page declares, which is not known until after it parses.
public final class CustomSidebarWebContainerView: NSView {
    let webView: WKWebView

    var insets: CustomSidebarWebInsets = .zero {
        didSet { if insets != oldValue { needsLayout = true } }
    }

    /// `true` once the page declares `viewport-fit=cover`. Defaults to `false` so a page that says
    /// nothing is laid out safely.
    var isFullBleed: Bool = false {
        didSet { if isFullBleed != oldValue { needsLayout = true } }
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layout() {
        super.layout()
        if isFullBleed {
            webView.frame = bounds
        } else {
            // Shrinking the frame — rather than padding the page — keeps viewport units honest, so a
            // page built around `height: 100vh` fills the usable area instead of overflowing by the
            // height of the chrome.
            webView.frame = CGRect(
                x: bounds.minX,
                y: bounds.minY + insets.bottom,
                width: bounds.width,
                height: max(0, bounds.height - insets.top - insets.bottom)
            )
        }
    }
}
