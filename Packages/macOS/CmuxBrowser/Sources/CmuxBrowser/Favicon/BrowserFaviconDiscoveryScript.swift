public import Foundation

/// The page-side favicon discovery script plus the parsing of its result into a `URL`.
///
/// ``source`` is an immediately-invoked function expression that scans the document for
/// `<link rel="icon">` and friends, scores each candidate by its declared `sizes` (with `any`
/// winning outright), and evaluates to the best icon's `href` string (or `""`). Evaluate it in
/// the page, then feed the returned string to ``parse(href:)`` to recover an absolute or
/// document-relative `URL`.
public struct BrowserFaviconDiscoveryScript: Sendable, Equatable {
    /// Creates a discovery-script value. The type carries the static ``source`` and a stateless
    /// ``parse(href:)``; the initializer lets callers hold a value instead of a static namespace.
    public init() {}

    /// JavaScript that returns the highest-scoring favicon `href` in the document, or `""`.
    ///
    /// Candidates are the `icon`, `shortcut icon`, and `apple-touch-icon[-precomposed]` link
    /// tags. Each is scored by the largest pixel dimension parsed out of its `sizes` value;
    /// `sizes="any"` scores 1000 so it always wins. The links are sorted descending by score and
    /// the first one's `href` is returned.
    public static let source: String = """
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

    /// Parses an `href` string returned by ``source`` into a `URL`.
    ///
    /// - Parameter href: The raw `href` string from the page (may be empty or whitespace-padded).
    /// - Returns: The trimmed `href` as a `URL`, or `nil` when it is empty or not URL-parseable.
    public func parse(href: String) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return url
    }
}
