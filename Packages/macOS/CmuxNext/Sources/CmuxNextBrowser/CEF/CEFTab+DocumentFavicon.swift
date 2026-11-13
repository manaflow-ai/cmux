import Foundation

/// The favicon of a document Chromium never reported one for (https://github.com/manaflow-ai/cmux/issues/42435).
///
/// Chromium reports a document's favicon (OnFaviconURLChange) when the document parses its icon links, and drops
/// the report while the document is not yet the tab's page. A page restored from the back/forward cache, or
/// activated from a prerender (a search result the search page prerendered), parsed its links before then, so its
/// commit brings no report, and a commit on another host has already cleared the old site's icon: the tab showed
/// the globe. Chrome's favicon driver reads such a document's icon list at its commit
/// (`WebContents::GetFaviconURLs`, which CEF does not expose); cmux reads the same list from the document once its
/// load stops without a report: one isolated-world read, only for those documents.
extension CEFTab {
    /// The document's first icon link (`rel` with the `icon` token, as Blink's favicon candidates), resolved; "" for
    /// none. Run in cmux's isolated world, where the page cannot patch what it answers.
    nonisolated static let documentFaviconScript = """
        (() => { const icon = Array.from(document.querySelectorAll('link[rel][href]')).find(l => l.relList.contains('icon')); \
        return icon ? icon.href : ''; })()
        """

    /// A new document committed: its favicon is not reported yet, and a read for the one before is not its.
    func documentFaviconCommitted() {
        faviconReported = false
        documentFaviconRead?.cancel()
        documentFaviconRead = nil
    }

    /// Chromium reported the document's favicon: no read needed, and a read in flight must not replace it.
    func documentFaviconReported() {
        faviconReported = true
        documentFaviconRead?.cancel()
        documentFaviconRead = nil
    }

    /// The load stopped: reads the committed web document's icon list when Chromium reported none for it.
    func readDocumentFaviconIfUnreported() {
        guard !faviconReported, documentFaviconRead == nil, !committedIsErrorPage, let page = committedURL,
              let scheme = page.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        documentFaviconRead = Task { [weak self] in
            let value = try? await self?.evaluate(Self.documentFaviconScript, world: .isolated, gesture: .cmux)
            guard let self, !Task.isCancelled, !self.faviconReported, self.committedURL == page else { return }
            self.documentFaviconRead = nil
            guard let icon = Self.documentFavicon(value, page: page) else { return }
            self.faviconReported = true
            self.machine.apply(.faviconChanged(icon))
            self.loadFavicon(icon)
        }
    }

    /// The icon address the read answered, else the site's `/favicon.ico` (Blink's default candidate for a page
    /// without an icon link); nil when the read failed.
    static func documentFavicon(_ value: BrowserJSValue?, page: URL) -> URL? {
        guard case .string(let href)? = value else { return nil }
        if !href.isEmpty, let url = URL(string: href) { return url }
        var site = URLComponents()
        site.scheme = page.scheme
        site.host = page.host()
        site.port = page.port
        site.path = "/favicon.ico"
        return site.url
    }
}
