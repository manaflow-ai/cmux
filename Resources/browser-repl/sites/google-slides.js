// sites.googleSlides: read and export Google Slides through Google's export
// endpoint in the signed-in session (no tab).
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL } = root.CmuxBrowserRepl.core;
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
        // there: a draft; setNotes(draftId, { confirm: true }) -> { status:
        // "notes set", slide, verified }.
        async setNotes(deck, index, text, options) {
          if (typeof deck === "string" && /^draft-\d+-[0-9a-f]+$/.test(deck)) return ed.edit("googleSlides", "setNotes", "googleSlides.setNotes", null, deck, index);
          if (!Number.isInteger(index) || index < 1) throw new S.SiteError("invalid", `googleSlides.setNotes: index: expected a slide number from 1, got ${JSON.stringify(index)}`);
          if (typeof text !== "string") throw new S.SiteError("invalid", "googleSlides.setNotes: text: expected text");
          const r = ref(deck, "googleSlides.setNotes", options || {});
          const norm = (x) => String(x).replace(/\s+/g, " ").trim();
          // Filmstrip thumbnails are g#filmstrip-slide-<position>-<object id>:
          // the object id (stable) of each slide, in deck order.
          const filmstrip = () => {
            const out = [];
            for (const g of document.querySelectorAll('[id^="filmstrip-slide-"]')) {
              const m = /^filmstrip-slide-(\d+)-(.+)$/.exec(g.id);
              if (m) out[Number(m[1])] = m[2];
            }
            return out.every((x) => typeof x === "string") ? out : null;
          };
          // The deck as the editor (object ids) and the export (titles,
          // notes) both show it: the editor's order read before and after
          // the export, so the export's slide at a position is the slide
          // with that position's id. Nothing when the two disagree (a
          // collaborator moved, added or removed a slide meanwhile).
          const both = async (page) => {
            const before = await t.readBack(page, filmstrip);
            const slides = await ed.deck("googleSlides.setNotes", r);
            const after = await t.readBack(page, filmstrip);
            if (!before || !after || before.join("\n") !== after.join("\n") || before.length !== slides.length) return null;
            return before.map((id, i) => ({ id, title: slides[i].title, notes: slides[i].notes }));
          };
          return ed.edit("googleSlides", "setNotes", "googleSlides.setNotes", r, {}, options, async (page) => {
            // The draft names the slide by its object id and the title the
            // export gives the slide with that id; the write requires both
            // again, at the same position.
            const slides = await both(page);
            if (!slides) throw new S.SiteError("target_unverified", "googleSlides.setNotes: the editor's slides and the deck's export disagree (a collaborator is moving slides); nothing was drafted. Try again");
            if (index > slides.length) throw new S.SiteError("invalid", `googleSlides.setNotes: slide ${index} does not exist; the deck has ${slides.length} slides`);
            const slide = slides[index - 1];
            if (!/^[\w-]+$/.test(slide.id)) throw new S.SiteError("target_unverified", `googleSlides.setNotes: slide ${index} has no object id in the editor's filmstrip`);
            return {
              summary: `Set the speaker notes of slide ${index} ("${slide.title}", object ${slide.id}) in Google Slides ${r.id}`,
              target: { slide: index, slideId: slide.id, slideTitle: slide.title },
              content: { notes: text },
              sent: ["notes"],
              observe: async (p) => {
                const now = await both(p);
                const at = now ? now.findIndex((x) => x.id === slide.id) : -1;
                if (!now) return {};
                if (at < 0) return { slideId: null };
                return { slide: at + 1, slideId: slide.id, slideTitle: now[at].title };
              },
              act: (p) => setNotesOn(p, `[id="filmstrip-slide-${index - 1}-${slide.id}"]`, index),
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
        // a draft; replace(draftId, { confirm: true }) -> { status: "replaced", count, verified }.
        async replace(deck, find, replacement, options) {
          if (typeof deck === "string" && /^draft-\d+-[0-9a-f]+$/.test(deck)) return ed.edit("googleSlides", "replace", "googleSlides.replace", null, deck, find);
          if (typeof find !== "string" || !find) throw new S.SiteError("invalid", "googleSlides.replace: find: expected text");
          // Read once, so the preview and the edit use the same text.
          replacement = String(replacement);
          const r = ref(deck, "googleSlides.replace", options || {});
          const occurrences = (slides) => slides.flatMap((s) => [...s.text, s.notes]).reduce((n, x) => n + (x.split(find).length - 1), 0);
          // The deck (pptx export: slide text and notes) as its hash, and
          // the matches per slide, case ignored as Find and replace does.
          // Replace all edits every match, so the write runs only on that
          // same deck, read again right before it.
          const read = async () => {
            const slides = await ed.deck("googleSlides.replace", r);
            const at = slides.map((s) => ({ slide: s.index, matches: ed.matchesIn([...s.text, s.notes].join("\n"), find).length })).filter((x) => x.matches);
            return { matches: at.reduce((n, x) => n + x.matches, 0), at, deckHash: t.hash(JSON.stringify(slides)) };
          };
          return ed.edit("googleSlides", "replace", "googleSlides.replace", r, {}, options, async () => {
            const drafted = await read();
            return {
              summary: `Replace ${drafted.matches} match(es) of "${find}" (case ignored) with "${replacement}" in Google Slides ${r.id}`,
              content: { find, replace: replacement, ...drafted },
              sent: ["find", "replace"],
              observe: read,
              act: async (page) => {
                await ed.findReplace(page, find, replacement);
                const verified = drafted.matches === 0 || replacement.includes(find) || (await ed.verify(async () => occurrences(await ed.deck("googleSlides.replace", r)) === 0));
                return { status: "replaced", count: drafted.matches, verified };
              },
            };
          });
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
    { summary: "Read (text) and export (pptx/pdf/...) Google Slides; confirmed-draft edits", writes: ["setNotes", "replace"] },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
