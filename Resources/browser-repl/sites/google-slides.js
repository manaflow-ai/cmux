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
          const slides = await ed.deck("googleSlides.setNotes", r);
          const count = slides.length;
          if (index > count) throw new S.SiteError("invalid", `googleSlides.setNotes: slide ${index} does not exist; the deck has ${count} slides`);
          const norm = (x) => String(x).replace(/\s+/g, " ").trim();
          // Filmstrip thumbnails are g#filmstrip-slide-<position>-<object id>:
          // the object id stays with the slide when slides move.
          const findSlide = (arg) => {
            for (const g of document.querySelectorAll('[id^="filmstrip-slide-"]')) {
              const m = /^filmstrip-slide-(\d+)-(.+)$/.exec(g.id);
              if (m && (arg.id === undefined ? Number(m[1]) === arg.position : m[2] === arg.id)) return { position: Number(m[1]), id: m[2] };
            }
            return null;
          };
          return ed.edit("googleSlides", "setNotes", "googleSlides.setNotes", r, {}, options, async (label, page) => {
            // The draft names the slide by its object id, read from the
            // editor now; the write finds that slide wherever it moved.
            const found = await page.evaluate(findSlide, { position: index - 1 });
            if (!found || !/^[\w-]+$/.test(found.id)) throw new S.SiteError("not_found", `googleSlides.setNotes: slide ${index} is not in the editor's filmstrip`);
            const slideId = found.id;
            const slideTitle = slides[index - 1].title;
            return {
              summary: `Set the speaker notes of slide ${index} ("${slideTitle}", object ${slideId}) in Google Slides ${r.id}`,
              preview: { file: deck, slide: index, slideId, slideTitle, notes: text },
              run: async (page, gate) => {
                await gate();
                const now = await page.evaluate(findSlide, { id: slideId });
                if (!now) throw new S.SiteError("slide_changed", `googleSlides.setNotes: slide ${slideId} ("${slideTitle}") is no longer in the deck; nothing was changed`);
                const at = now.position + 1;
                return setNotesOn(page, `[id="filmstrip-slide-${now.position}-${slideId}"]`, at);
              },
            };
          });
          // The slide's thumbnail in the filmstrip, then the notes box, with typed keys.
          async function setNotesOn(page, thumbnail, at) {
            await page.locator(thumbnail).first().click();
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
            const verified = await ed.verify(async () => norm((await ed.deck("googleSlides.setNotes", r))[at - 1].notes) === norm(text));
            return { status: "notes set", slide: at, verified };
          }
        },
        // Replaces every occurrence of `find` in the deck (Find and replace):
        // { status: "replaced", count, verified }. Private deck: at once; else a draft.
        async replace(deck, find, replacement, options) {
          if (typeof deck === "string" && /^draft-\d+-[0-9a-f]+$/.test(deck)) return ed.edit("googleSlides", "replace", "googleSlides.replace", null, deck, find);
          if (typeof find !== "string" || !find) throw new S.SiteError("invalid", "googleSlides.replace: find: expected text");
          // Read once, so the preview and the edit use the same text.
          replacement = String(replacement);
          const r = ref(deck, "googleSlides.replace", options || {});
          const occurrences = (slides) => slides.flatMap((s) => [...s.text, s.notes]).reduce((n, x) => n + (x.split(find).length - 1), 0);
          // The deck as drafted (pptx export: slide text and notes) and the
          // matches per slide, case ignored as Find and replace does. Replace
          // all edits every match, so the write runs only on that same deck,
          // read again right before it (document_changed otherwise).
          const drafted = await ed.deck("googleSlides.replace", r);
          const draftedJSON = JSON.stringify(drafted);
          const at = drafted.map((s) => ({ slide: s.index, matches: ed.matchesIn([...s.text, s.notes].join("\n"), find).length })).filter((x) => x.matches);
          const total = at.reduce((n, x) => n + x.matches, 0);
          return ed.edit("googleSlides", "replace", "googleSlides.replace", r, {}, options, () => ({
            summary: `Replace ${total} match(es) of "${find}" (case ignored) with "${replacement}" in Google Slides ${r.id}`,
            preview: { file: deck, find, replace: replacement, matches: total, at },
            run: async (page, gate) => {
              await gate();
              const now = await ed.deck("googleSlides.replace", r);
              if (JSON.stringify(now) !== draftedJSON) throw new S.SiteError("document_changed", `googleSlides.replace: the deck changed since the ${total} match(es) were counted; nothing was changed. Make a new call (a new draft for a shared deck)`);
              await ed.findReplace(page, find, replacement);
              const verified = total === 0 || replacement.includes(find) || (await ed.verify(async () => occurrences(await ed.deck("googleSlides.replace", r)) === 0));
              return { status: "replaced", count: total, verified };
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
