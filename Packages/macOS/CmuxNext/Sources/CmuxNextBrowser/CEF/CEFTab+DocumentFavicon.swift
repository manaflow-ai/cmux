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
}
