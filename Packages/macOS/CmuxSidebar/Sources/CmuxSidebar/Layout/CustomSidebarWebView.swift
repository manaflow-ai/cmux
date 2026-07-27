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

    public init(source: CustomSidebarWebSource, insets: CustomSidebarWebInsets = .zero) {
        self.source = source
        self.insets = insets
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

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // The page paints its own background. Letting the web view draw one flashes white on every
        // load, which is jarring against the sidebar's chrome in dark mode.
        webView.setValue(false, forKey: "drawsBackground")
        // A sidebar is not a browser: swiping should not navigate away from the page, leaving the
        // user on a blank view with no visible way back.
        webView.allowsBackForwardNavigationGestures = false

        let container = CustomSidebarWebContainerView(webView: webView)
        container.insets = insets
        context.coordinator.container = container
        context.coordinator.load(source, into: webView)
        return container
    }

    public func updateNSView(_ container: CustomSidebarWebContainerView, context: Context) {
        context.coordinator.container = container
        if container.insets != insets {
            container.insets = insets
            // The page keeps rendering while the chrome resizes, so the variables are refreshed in
            // place rather than by reloading and losing scroll position.
            container.webView.evaluateJavaScript(
                "window.__cmuxSidebarSetInsets && window.__cmuxSidebarSetInsets(\(insets.top), \(insets.bottom))",
                completionHandler: nil
            )
        }
        context.coordinator.load(source, into: container.webView)
    }

    public static func dismantleNSView(_ container: CustomSidebarWebContainerView, coordinator: Coordinator) {
        // The content controller retains its message handlers, so leaving this registered would keep
        // the coordinator (and through it the container) alive after the sidebar is swapped away.
        container.webView.configuration.userContentController.removeScriptMessageHandler(
            forName: CustomSidebarWebView.viewportMessageName
        )
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
        weak var container: CustomSidebarWebContainerView?

        /// Loads only when the source actually changed.
        ///
        /// `updateNSView` runs on unrelated SwiftUI invalidations — and the custom sidebar is
        /// mounted inside a one-second `TimelineView` — so reloading unconditionally would discard
        /// the page's scroll position, filter text, and open menus roughly once a second.
        func load(_ source: CustomSidebarWebSource, into webView: WKWebView) {
            guard loadedSource != source else { return }
            loadedSource = source
            // A reload replaces the document, so any previous full-bleed opt-in no longer applies;
            // the incoming page re-declares it or gets the safe default.
            container?.isFullBleed = false
            switch source {
            case let .document(fileURL):
                // Read access is scoped to the document's own directory so a sidebar can pull in
                // sibling assets without being handed the rest of the filesystem.
                webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            case let .remote(url):
                webView.load(URLRequest(url: url))
            }
        }

        nonisolated public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
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
