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
        // Sets one slide's speaker notes (1-based index), replacing what is
        // there: { status: "notes set", slide, verified }. Private deck: at once; else a draft.
        async setNotes(deck, index, text, options) {
          if (typeof deck === "string" && /^draft-\d+-[0-9a-f]+$/.test(deck)) return ed.edit("googleSlides", "setNotes", "googleSlides.setNotes", null, deck, index);
          if (!Number.isInteger(index) || index < 1) throw new S.SiteError("invalid", `googleSlides.setNotes: index: expected a slide number from 1, got ${JSON.stringify(index)}`);
          if (typeof text !== "string") throw new S.SiteError("invalid", "googleSlides.setNotes: text: expected text");
          const r = ref(deck, "googleSlides.setNotes", options || {});
          const count = (await ed.deck("googleSlides.setNotes", r)).length;
          if (index > count) throw new S.SiteError("invalid", `googleSlides.setNotes: slide ${index} does not exist; the deck has ${count} slides`);
          const norm = (x) => String(x).replace(/\s+/g, " ").trim();
          return ed.edit("googleSlides", "setNotes", "googleSlides.setNotes", r, {}, options, () => ({
            summary: `Set the speaker notes of slide ${index} in Google Slides ${r.id}`,
            preview: { file: deck, slide: index, notes: text },
            run: async (page) => {
              // The slide's thumbnail in the filmstrip, then the notes box, with typed keys.
              await page.locator(`[id^="filmstrip-slide-${index - 1}-"]`).first().click();
              await t.sleep(500);
              await page.locator("#speakernotes-workspace").click();
              await t.sleep(300);
              // Select all notes (Meta+A selects nothing there): to the start, then to the end; delete.
              await page.keyboard.press("Meta+ArrowUp");
              await page.keyboard.press("Meta+Shift+ArrowDown");
              await page.keyboard.press("Delete");
              const lines = text.split("\n");
              for (let i = 0; i < lines.length; i++) {
                if (i) await page.keyboard.press("Enter");
                if (lines[i]) await page.keyboard.type(lines[i]);
              }
              await page.keyboard.press("Escape");
              await ed.saved(page);
              const verified = await ed.verify(async () => norm((await ed.deck("googleSlides.setNotes", r))[index - 1].notes) === norm(text));
              return { status: "notes set", slide: index, verified };
            },
          }));
        },
        // Replaces every occurrence of `find` in the deck (Find and replace):
        // { status: "replaced", count, verified }. Private deck: at once; else a draft.
        replace(deck, find, replacement, options) {
          if (typeof deck === "string" && /^draft-\d+-[0-9a-f]+$/.test(deck)) return ed.edit("googleSlides", "replace", "googleSlides.replace", null, deck, find);
          if (typeof find !== "string" || !find) throw new S.SiteError("invalid", "googleSlides.replace: find: expected text");
          // Read once, so the preview and the edit use the same text.
          replacement = String(replacement);
          const r = ref(deck, "googleSlides.replace", options || {});
          const occurrences = async () => (await ed.deck("googleSlides.replace", r)).flatMap((s) => [...s.text, s.notes]).reduce((n, x) => n + (x.split(find).length - 1), 0);
          return ed.edit("googleSlides", "replace", "googleSlides.replace", r, {}, options, () => ({
            summary: `Replace "${find}" with "${replacement}" in Google Slides ${r.id}`,
            preview: { file: deck, find, replace: replacement },
            run: async (page) => {
              const before = await occurrences();
              await ed.findReplace(page, find, replacement);
              const verified = before === 0 || replacement.includes(find) || (await ed.verify(async () => (await occurrences()) === 0));
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
