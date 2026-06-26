import Foundation

/// A snippet of JavaScript source built for the markdown WKWebView shell.
///
/// Each factory assembles the exact script string the markdown renderer used
/// to build inline before handing it to `WKWebView.evaluateJavaScript`. The
/// value carries only the built ``source``; evaluation, completion handling,
/// and `#if DEBUG` logging stay app-side at the call site. Splitting the pure
/// string building out keeps the renderer coordinator focused on live WebView
/// state and makes the produced JavaScript directly testable.
struct MarkdownRenderScript: Sendable, Equatable {
    /// The JavaScript source to hand to `WKWebView.evaluateJavaScript`.
    let source: String

    /// Drives the shell's body zoom through the `__cmuxSetMarkdownZoom` helper.
    /// `zoom` is the resolved `pageZoom` factor for the desired point size.
    static func setMarkdownZoom(_ zoom: Double) -> MarkdownRenderScript {
        MarkdownRenderScript(source: "window.__cmuxSetMarkdownZoom && window.__cmuxSetMarkdownZoom(\(Double(zoom)));")
    }

    /// Applies an inline `font-family` override to the `#content` element.
    /// `css` is the resolved CSS value; an empty string clears the override.
    static func setContentFontFamily(css: String) -> MarkdownRenderScript {
        // JSON-encode the CSS value (empty string clears the override).
        let encoded = (try? JSONSerialization.data(withJSONObject: [css]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return MarkdownRenderScript(source: """
        (function(arr) {
          var content = document.getElementById('content');
          if (content) { content.style.fontFamily = arr[0]; }
        })(\(encoded));
        """)
    }

    /// Applies an inline `max-width` (in CSS pixels) to the `#content` element.
    static func setContentMaxWidth(_ width: Int) -> MarkdownRenderScript {
        MarkdownRenderScript(source: """
        (function(width) {
          var content = document.getElementById('content');
          if (content) { content.style.maxWidth = width + 'px'; }
        })(\(width));
        """)
    }

    /// Pushes theme CSS variables onto the `#content` element and nudges the
    /// page to re-apply its theme. `payload` maps CSS variable names to color
    /// strings. Returns `nil` when the payload cannot be JSON-encoded.
    static func applyThemeVariables(_ payload: [String: String]) -> MarkdownRenderScript? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return MarkdownRenderScript(source: """
        (function(vars) {
          var content = document.getElementById('content');
          if (!content) { return; }
          Object.keys(vars).forEach(function(name) {
            content.style.setProperty(name, vars[name]);
          });
          content.style.background = 'transparent';
          if (window.__cmuxApplyTheme) { window.__cmuxApplyTheme(); }
        })(\(json));
        """)
    }

    /// Renders markdown through the page's `__cmuxRenderMarkdown` helper, with a
    /// raw-source `<pre>` fallback if the helper has not initialized. The raw
    /// markdown is sent through a JSON literal so backticks, backslashes, and
    /// quotes need no hand-escaping. Returns `nil` when the markdown cannot be
    /// JSON-encoded.
    static func renderMarkdown(_ markdown: String) -> MarkdownRenderScript? {
        // Send the raw markdown through a JSON literal so we don't have
        // to hand-escape backticks/backslashes/quotes for JS.
        guard let data = try? JSONSerialization.data(withJSONObject: [markdown]),
              let arrayLiteral = String(data: data, encoding: .utf8) else { return nil }
        return MarkdownRenderScript(source: """
        (function(md) {
          if (window.__cmuxRenderMarkdown) {
            window.__cmuxRenderMarkdown(md);
            return;
          }
          var el = document.getElementById('content') || document.body;
          function esc(s) {
            var div = document.createElement('div');
            div.textContent = String(s == null ? '' : s);
            return div.innerHTML;
          }
          el.innerHTML = '<pre style=\"color:#f85149;white-space:pre-wrap\">Markdown renderer failed to initialize. Showing raw source.\\n\\n' + esc(md) + '</pre>';
        })(\(arrayLiteral)[0]);
        """)
    }

    /// Concatenates lazy-loaded library `sources` into a single evaluation and
    /// notifies the page via `__cmuxLibLoaded`. `lib` is JSON-encoded before
    /// being spliced into JS. Empty sources are skipped.
    static func loadLibrary(named lib: String, sources: [String]) -> MarkdownRenderScript {
        // Concatenate the bundled sources into a single evaluateJavaScript
        // call, then notify the page that the lib is ready. Any parse or
        // throw in the bundle surfaces through the completion handler.
        var injection = ""
        for src in sources where !src.isEmpty {
            injection += src
            injection += "\n;"
        }
        // JSON-encode the lib name to safely splice into JS.
        let libLiteral = (try? JSONSerialization.data(withJSONObject: [lib]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let suffix = "\nwindow.__cmuxLibLoaded && window.__cmuxLibLoaded(\(libLiteral)[0]);"
        return MarkdownRenderScript(source: injection + suffix)
    }
}
