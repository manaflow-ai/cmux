import Foundation

/// The one-shot offline document used by HTML/SVG artifact cards. It lives on the agent page's
/// origin only so the page's frame CSP can name one exact endpoint, while the response sandbox
/// gives the rendered document an opaque origin even when the iframe's HTML is rewritten.
nonisolated enum PageArtifactFrame {
    static let endpoint = "cmux-page://cmux.agent/__artifact"
    static let pageID = "cmux.agent"
    static let path = "/__artifact"
    static let csp = "sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors cmux-page://cmux.agent"

    /// The endpoint host/path, allowing a query or fragment so navigation can refuse it as a
    /// self-navigation. `isFrame` below is the exact request served by the scheme handler.
    static func isArtifactURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == PageDescriptor.scheme,
              url.host?.lowercased() == pageID,
              url.port == nil, url.user == nil, url.password == nil,
              url.path == path else { return false }
        return true
    }

    /// The exact endpoint request. Queries and fragments are refused rather than served.
    static func isFrame(_ url: URL?) -> Bool {
        guard isArtifactURL(url), let url else { return false }
        return url.absoluteString == endpoint
    }

    static func isAgentPageURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == PageDescriptor.scheme,
              url.host?.lowercased() == pageID,
              url.port == nil, url.user == nil, url.password == nil else { return false }
        return true
    }

    /// A frame that is already an artifact, or a passive srcdoc artifact, cannot navigate or load
    /// another document. The parent check prevents an ordinary page's srcdoc from being widened.
    static func contextRestricted(frame: URL?, parent: URL?) -> Bool {
        isArtifactURL(frame) || isArtifactURL(parent) ||
            (frame?.absoluteString == "about:srcdoc" && isAgentPageURL(parent))
    }

    /// Only an empty/about:blank direct child of the agent page may load the endpoint once.
    static func navigationRefused(mainFrame: Bool, frame: URL?, parent: URL?, target: URL?) -> Bool {
        if contextRestricted(frame: frame, parent: parent) { return true }
        guard isArtifactURL(target) else { return false }
        guard isFrame(target), !mainFrame, isAgentPageURL(parent) else { return true }
        return frame != nil && frame?.absoluteString != "about:blank"
    }

    /// The bootstrap's one-shot postMessage protocol. The parent owns the HTML and CSS strings;
    /// this document never receives a bridge or a network capability.
    static let document = Data(#"""
    <!doctype html>
    <html><head><meta charset="utf-8"><script>
    "use strict";
    (function () {
      var host = parent;
      function size() {
        var body = document.body;
        host.postMessage({type:"cmux-render-size",height:Math.ceil(Math.max(
          document.documentElement.scrollHeight,body ? body.scrollHeight : 0))},"*");
      }
      function show(event) {
        var data = event.data;
        if (event.source !== host || !data || data.type !== "cmux-render" || typeof data.html !== "string") return;
        removeEventListener("message",show);
        document.open(); document.write(data.html); document.close();
        var theme = document.createElement("style");
        theme.textContent = typeof data.css === "string" ? data.css : "";
        var head = document.head || document.documentElement;
        head.insertBefore(theme,head.firstChild);
        new ResizeObserver(size).observe(document.documentElement);
        addEventListener("load",size); size();
      }
      addEventListener("message",show);
      host.postMessage({type:"cmux-render-ready"},"*");
    })();
    </script></head></html>
    """#.utf8)
}
