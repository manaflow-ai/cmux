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
      const ed = S.shared.editors.create(t);
      const ref = (deck, name, options = {}) => {
        const r = g.parse(deck, name, "presentation");
        if (options.uid !== undefined) r.uid = options.uid;
        return r;
      };
      return {
        // [{ index, title, text: [paragraphs], notes }] from the pptx export.
        async slides(deck, options = {}) {
          return ed.deck("googleSlides.slides", ref(deck, "googleSlides.slides", options));
        },
        // Replaces every occurrence of `find` in the deck (Find and replace):
        // { status: "replaced", count, verified }. Private deck: at once; else a draft.
        replace(deck, find, replacement, options) {
          if (typeof deck === "string" && /^draft-\d+-[0-9a-f]+$/.test(deck)) return ed.edit("googleSlides", "replace", "googleSlides.replace", null, deck, find);
          if (typeof find !== "string" || !find) throw new S.SiteError("invalid", "googleSlides.replace: find: expected text");
          const r = ref(deck, "googleSlides.replace", options || {});
          const occurrences = async () => (await ed.deck("googleSlides.replace", r)).flatMap((s) => [...s.text, s.notes]).reduce((n, x) => n + (x.split(find).length - 1), 0);
          return ed.edit("googleSlides", "replace", "googleSlides.replace", r, {}, options, () => ({
            summary: `Replace "${find}" with "${replacement}" in Google Slides ${r.id}`,
            preview: { file: deck, find, replace: String(replacement) },
            run: async (page) => {
              const before = await occurrences();
              await ed.findReplace(page, find, String(replacement));
              const verified = before === 0 || String(replacement).includes(find) || (await ed.verify(async () => (await occurrences()) === 0));
              return { status: "replaced", count: before, verified };
            },
          }));
        },
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
