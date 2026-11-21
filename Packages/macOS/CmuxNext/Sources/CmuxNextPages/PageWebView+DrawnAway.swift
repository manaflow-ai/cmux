public import AppKit

/// A page its host keeps drawn while no pane shows it (a chat tab switched away from, `AgentPageDrawnParking`).
/// Its engine keeps drawing it off screen, so showing it again shows its last frame at once: a Chromium page
/// told it is hidden drops its frame and drew nothing for 0.5 to 1.25 s on the switch back (Leo, 2026-11-15:
/// "there is layout shift here... why..."). To the document and to the page's owner it is hidden all the same:
/// `document.visibilityState` reads "hidden" and a `visibilitychange` fires, so a turn that ends meanwhile stays
/// unread, its animations stop and its question keys are revoked, as for a hidden page.
extension PageWebView {
    /// Marks the page away (true) or shown again (false). The view's own visibility does not change.
    public func setDrawnAway(_ away: Bool) {
        guard isDrawnAway != away else { return }
        isDrawnAway = away
        evaluateInPage(Self.drawnAwayScript(away))
        if away {
            chromiumSession?.questionKeys?.invalidate()
            popupHost?.dismiss()
        }
        onVisibilityChanged?(!away && window != nil && !isHiddenOrHasHiddenAncestor)
        healthFeed?.pageVisibilityChanged(self)
    }

    /// A new document (a reload or navigation while away) starts shown: marks it away again.
    public func reapplyDrawnAway() {
        if isDrawnAway { evaluateInPage(Self.drawnAwayScript(true)) }
    }

    /// The document's side of ``setDrawnAway(_:)``: `document.visibilityState` and `document.hidden` answer
    /// "hidden" while away (the engine's own answer otherwise), and a change fires `visibilitychange`.
    /// Installed once per document; a reloaded document starts shown.
    static func drawnAwayScript(_ away: Bool) -> String {
        """
        (() => {
          const d = document, w = window;
          if (!w.__cmuxDrawnAway) {
            const state = Object.getOwnPropertyDescriptor(Document.prototype, "visibilityState");
            const hidden = Object.getOwnPropertyDescriptor(Document.prototype, "hidden");
            w.__cmuxDrawnAway = { away: false };
            Object.defineProperty(d, "visibilityState", { configurable: true, get: () => w.__cmuxDrawnAway.away ? "hidden" : state.get.call(d) });
            Object.defineProperty(d, "hidden", { configurable: true, get: () => w.__cmuxDrawnAway.away || hidden.get.call(d) });
          }
          const away = \(away ? "true" : "false");
          if (w.__cmuxDrawnAway.away === away) return;
          w.__cmuxDrawnAway.away = away;
          d.dispatchEvent(new Event("visibilitychange"));
        })();
        """
    }
}
