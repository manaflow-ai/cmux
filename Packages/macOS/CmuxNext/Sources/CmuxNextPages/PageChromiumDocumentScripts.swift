public import WebKit

/// The WebKit user scripts of a page, made into Chromium new-document scripts, plus the script that
/// sends link clicks to the host. A ``PageWebView`` installs its scripts on its WebKit
/// configuration (theme, readiness, console capture, paint probe, `data-*` attributes); a Chromium
/// page gets the same ones, in the same order.
public nonisolated struct PageChromiumDocumentScripts: Sendable, Equatable {
    /// The handler a link click to another origin posts to (``navigationScript``).
    public static let navigateHandler = "cmuxPageNavigate"
    /// The handler a drop the host takes posts to (``hostDropScript``).
    public static let hostDropHandler = "cmuxPageHostDrop"
    /// The handler every drop of files on the page posts to, whoever takes it (``hostDropScript``):
    /// the host learns the drop of a drag it saw enter (``PageWebView/onFilesDropped``).
    public static let pageDropHandler = "cmuxPageFilesDropped"

    /// The scripts, in install order.
    public let sources: [String]

    /// - Parameter scripts: Each WebKit user script's source, time and frame scope.
    public init(scripts: [(source: String, atDocumentEnd: Bool, mainFrameOnly: Bool)]) {
        sources = scripts.map(Self.chromiumSource) + [Self.navigationScript, Self.hostDropScript]
    }

    /// The user scripts of `controller`.
    ///
    /// - Parameter controller: A page's WebKit user content controller.
    @MainActor
    public init(controller: WKUserContentController) {
        self.init(scripts: controller.userScripts.map {
            ($0.source, $0.injectionTime == .atDocumentEnd, $0.isForMainFrameOnly)
        })
    }

    /// Chromium runs a new-document script in every frame, before the document parses: a main-frame
    /// script returns in subframes, and a document-end script waits for `DOMContentLoaded`.
    static func chromiumSource(_ script: (source: String, atDocumentEnd: Bool, mainFrameOnly: Bool)) -> String {
        let guardFrame = script.mainFrameOnly ? "if (window !== window.top) return;\n" : ""
        guard script.atDocumentEnd else {
            return "(() => {\n\(guardFrame)\(script.source)\n})();"
        }
        return """
        (() => {
        \(guardFrame)const run = () => {
        \(script.source)
        };
        if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", run, { once: true }); else run();
        })();
        """
    }

    /// A file drop the host takes (``PageWebView/fileDrop``). WebKit hands such a drag to the host
    /// before the page sees it; in Chromium the host learns the drag's files when it enters
    /// (``PageChromiumEvent/filesDragged(_:)``) and turns this script on with
    /// `__cmuxHostDrop(true)`. The page's own drag handlers then never get the drop: the script
    /// takes `dragover` and `drop` in the capture phase and tells the host, which opens the file.
    static let hostDropScript = """
    (() => {
      if (window !== window.top) return;
      let take = false;
      window.__cmuxHostDrop = (value) => { take = value === true; };
      const hasFiles = (event) => !!event.dataTransfer && Array.from(event.dataTransfer.types || []).includes("Files");
      window.addEventListener("dragover", (event) => {
        if (!take || !hasFiles(event)) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        event.dataTransfer.dropEffect = "copy";
      }, true);
      window.addEventListener("drop", (event) => {
        if (hasFiles(event)) {
          try { window.webkit.messageHandlers.\(pageDropHandler).postMessage({}); } catch (_) {}
        }
        if (!take || !hasFiles(event)) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        take = false;
        try { window.webkit.messageHandlers.\(hostDropHandler).postMessage({}); } catch (_) {}
      }, true);
    })();
    """

    /// WebKit asks the host before a link leaves the page's origin (`decidePolicyFor`); Chromium
    /// pages have no such hook here, so a click on a link to another origin that the page itself
    /// did not handle goes to the host, which applies the same rule (``PageNavigation``). It listens
    /// on `window` in the bubble phase, so the page's own handlers run first.
    static let navigationScript = """
    (() => {
      if (window !== window.top) return;
      window.addEventListener("click", (event) => {
        if (event.defaultPrevented || event.button > 1) return;
        const link = event.composedPath().find((node) => node instanceof HTMLAnchorElement && node.href);
        if (!link) return;
        const url = new URL(link.href, location.href);
        const sameOrigin = url.protocol === location.protocol && url.host === location.host;
        if (sameOrigin && !link.target && event.button === 0) return;
        event.preventDefault();
        try {
          window.webkit.messageHandlers.\(navigateHandler).postMessage({
            url: url.href, command: event.metaKey, shift: event.shiftKey, option: event.altKey, control: event.ctrlKey,
          });
        } catch (_) {}
      });
    })();
    """
}
