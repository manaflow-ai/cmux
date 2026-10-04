// sites.googleDocs: read and export Google Docs through Google's export
// endpoint in the signed-in session (no tab).
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  S.register(
    "googleDocs",
    (t) => {
      const g = S.shared.google;
      const ed = S.shared.editors.create(t);
      const ref = (doc, name, options = {}) => {
        const r = g.parse(doc, name, "document");
        if (options.uid !== undefined) r.uid = options.uid;
        return r;
      };
      const plain = async (r) => (await g.exportText(t, "googleDocs", r, "txt")).text.replace(/^\ufeff/, "");
      const count = (text, s) => (s ? text.split(s).length - 1 : 0);
      // Runs in a blank page: the HTML export as blocks.
      function blocksOf(arg) {
        const doc = new DOMParser().parseFromString(arg.html, "text/html");
        const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
        const out = [];
        for (const el of doc.body.children) {
          const tag = el.tagName;
          const h = /^H([1-6])$/.exec(tag);
          if (h) { const text = clean(el.textContent); if (text) out.push({ type: "heading", level: Number(h[1]), text }); }
          else if (tag === "P") { const text = clean(el.textContent); if (text) out.push({ type: "paragraph", text }); }
          else if (tag === "UL" || tag === "OL") {
            const items = [...el.querySelectorAll("li")].map((li) => clean(li.textContent));
            const prev = out[out.length - 1];
            if (prev && prev.type === "list" && prev.ordered === (tag === "OL")) prev.items.push(...items);
            else out.push({ type: "list", ordered: tag === "OL", items });
          } else if (tag === "TABLE") out.push({ type: "table", rows: [...el.querySelectorAll("tr")].map((tr) => [...tr.cells].map((c) => clean(c.textContent))) });
        }
        return out;
      }
      return {
        // { title, blocks: [{ type: heading|paragraph|list|table, ... }] } in document order.
        async structure(doc, options = {}) {
          const r = ref(doc, "googleDocs.structure", options);
          const { title, text } = await g.exportText(t, "googleDocs.structure", r, "html");
          return { title, blocks: await t.withTab("about:blank", (page) => page.evaluate(blocksOf, { html: text })) };
        },
        // Replaces every occurrence of `find` (Find and replace, match case off as in Docs):
        // { status: "replaced", count, verified }. Private doc: at once; else a draft.
        replace(doc, find, replacement, options) {
          if (typeof doc === "string" && /^draft-\d+-[0-9a-f]+$/.test(doc)) return ed.edit("googleDocs", "replace", "googleDocs.replace", null, doc, find);
          if (typeof find !== "string" || !find) throw new S.SiteError("invalid", "googleDocs.replace: find: expected text");
          // Read once, so the preview and the edit use the same text.
          replacement = String(replacement);
          const r = ref(doc, "googleDocs.replace", options || {});
          return ed.edit("googleDocs", "replace", "googleDocs.replace", r, {}, options, () => ({
            summary: `Replace "${find}" with "${replacement}" in Google Doc ${r.id}`,
            preview: { file: doc, find, replace: replacement },
            run: async (page, gate) => {
              const before = count(await plain(r), find);
              await gate();
              await ed.findReplace(page, find, replacement);
              const verified = before === 0 || (await ed.verify(async () => { const now = await plain(r); return replacement.includes(find) ? count(now, replacement) >= before : count(now, find) === 0; }));
              return { status: "replaced", count: before, verified };
            },
          }));
        },
        // Inserts text right after a unique anchor (a heading's text or any phrase): { status: "inserted", verified }.
        async insertAfter(doc, anchor, text, options) {
          if (typeof doc === "string" && /^draft-\d+-[0-9a-f]+$/.test(doc)) return ed.edit("googleDocs", "insertAfter", "googleDocs.insertAfter", null, doc, anchor);
          if (typeof anchor !== "string" || !anchor) throw new S.SiteError("invalid", "googleDocs.insertAfter: anchor: expected text");
          if (typeof text !== "string" || !text) throw new S.SiteError("invalid", "googleDocs.insertAfter: text: expected text");
          const r = ref(doc, "googleDocs.insertAfter", options || {});
          const n = count(await plain(r), anchor);
          if (n !== 1) throw new S.SiteError("invalid", `googleDocs.insertAfter: anchor ${JSON.stringify(anchor)} occurs ${n} times; it must occur exactly once`);
          return ed.edit("googleDocs", "insertAfter", "googleDocs.insertAfter", r, {}, options, () => ({
            summary: `Insert text after "${anchor}" in Google Doc ${r.id}`,
            preview: { file: doc, anchor, text },
            run: async (page, gate) => {
              await gate();
              await ed.findReplace(page, anchor, anchor + text);
              const verified = await ed.verify(async () => (await plain(r)).includes(anchor + text));
              return { status: "inserted", verified };
            },
          }));
        },
        // Appends a paragraph at the end of the document: { status: "appended", verified }.
        append(doc, text, options) {
          if (typeof doc === "string" && /^draft-\d+-[0-9a-f]+$/.test(doc)) return ed.edit("googleDocs", "append", "googleDocs.append", null, doc, text);
          if (typeof text !== "string" || !text) throw new S.SiteError("invalid", "googleDocs.append: text: expected text");
          const r = ref(doc, "googleDocs.append", options || {});
          return ed.edit("googleDocs", "append", "googleDocs.append", r, {}, options, () => ({
            summary: `Append a paragraph to Google Doc ${r.id}`,
            preview: { file: doc, text },
            run: async (page, gate) => {
              await gate();
              await page.locator(".kix-appview-editor").first().click();
              await page.keyboard.press("Meta+ArrowDown");
              await page.keyboard.press("Enter");
              await page.keyboard.insertText(text);
              const verified = await ed.verify(async () => (await plain(r)).trimEnd().endsWith(text));
              return { status: "appended", verified };
            },
          }));
        },
        // { title, text } as Markdown (default), "txt" or "html".
        async read(doc, options = {}) {
          const format = options.format || "md";
          if (!["md", "txt", "html"].includes(format)) throw new S.SiteError("invalid", `googleDocs.read: format: expected md, txt or html, got ${JSON.stringify(format)}`);
          const ref = g.parse(doc, "googleDocs.read", "document");
          if (options.uid !== undefined) ref.uid = options.uid;
          return g.exportText(t, "googleDocs.read", ref, format);
        },
        // Writes the document as md, pdf, docx, txt, html, odt, rtf or epub; { path, title, format }.
        async export(doc, options = {}) {
          const ref = g.parse(doc, "googleDocs.export", "document");
          if (options.uid !== undefined) ref.uid = options.uid;
          return g.exportTo(t, "googleDocs.export", ref, options.format || "md", options);
        },
      };
    },
    { summary: "Read (Markdown/text/HTML) and export (md/pdf/docx/...) Google Docs" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
