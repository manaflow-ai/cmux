// sites.googleSlides: read and export Google Slides through Google's export
// endpoint in the signed-in session (no tab).
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  S.register(
    "googleSlides",
    (t) => {
      const g = S.shared.google;
      return {
        // { title, text }: the slides' text, in order.
        async read(deck, options = {}) {
          const ref = g.parse(deck, "googleSlides.read", "presentation");
          if (options.uid !== undefined) ref.uid = options.uid;
          return g.exportText(t, "googleSlides.read", ref, "txt");
        },
        // Writes the deck as pptx, pdf, txt or odp; { path, title, format }.
        async export(deck, options = {}) {
          const ref = g.parse(deck, "googleSlides.export", "presentation");
          if (options.uid !== undefined) ref.uid = options.uid;
          return g.exportTo(t, "googleSlides.export", ref, options.format || "pptx", options);
        },
      };
    },
    { summary: "Read (text) and export (pptx/pdf/...) Google Slides" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
