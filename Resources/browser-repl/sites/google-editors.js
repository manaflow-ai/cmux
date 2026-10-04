// Shared editing helpers for Google Docs, Sheets and Slides
// (docs/browser-repl/site-tools.md, "Editing Google files"). Reads go through
// the editors' own export endpoints in the signed-in session; xlsx and pptx
// exports are unzipped in a docs.google.com page with the browser's
// DecompressionStream. Writes drive the editor in a background tab with real
// input: the Sheets name box and a paste from cmux's per-tab clipboard, the
// Docs and Slides Find and replace dialog, typing at the end of a document.
//
// Rule for writes: a file whose Share button says "Private to only me" is
// edited at once (nobody else sees it); any other file, or one whose
// sharing cannot be read, gets a draft first (reference B's confirmation
// taxonomy, [9]: edits others can see).
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;

  // Runs in a blank page (for DecompressionStream): unzips base64 bytes and
  // returns the text of entries whose names match arg.want.
  async function unzipExport(arg) {
    const bin = atob(arg.base64);
    const buf = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
    const r = { status: 200 };
    const view = new DataView(buf.buffer);
    let eocd = -1;
    for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65557); i--) if (view.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
    if (eocd < 0) return { status: r.status, error: "the export is not a zip file" };
    const count = view.getUint16(eocd + 10, true);
    let p = view.getUint32(eocd + 16, true);
    const want = new RegExp(arg.want);
    const out = {};
    const dec = new TextDecoder();
    for (let n = 0; n < count; n++) {
      const method = view.getUint16(p + 10, true);
      const size = view.getUint32(p + 20, true);
      const nameLen = view.getUint16(p + 28, true);
      const extraLen = view.getUint16(p + 30, true);
      const commentLen = view.getUint16(p + 32, true);
      const local = view.getUint32(p + 42, true);
      const name = dec.decode(buf.subarray(p + 46, p + 46 + nameLen));
      p += 46 + nameLen + extraLen + commentLen;
      if (!want.test(name)) continue;
      const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
      const data = buf.subarray(start, start + size);
      out[name] = method === 0 ? dec.decode(data) : await new Response(new Blob([data]).stream().pipeThrough(new DecompressionStream("deflate-raw"))).text();
    }
    return { status: r.status, files: out };
  }

  const xmlText = (s) => S.decodeEntities(String(s).replace(/<[^>]*>/g, ""));
  const colIndex = (letters) => [...letters].reduce((n, ch) => n * 26 + ch.charCodeAt(0) - 64, 0) - 1;
  const colName = (c) => {
    let s = "";
    for (c += 1; c > 0; c = Math.floor((c - 1) / 26)) s = String.fromCharCode(65 + ((c - 1) % 26)) + s;
    return s;
  };

  // xlsx parts -> [{ name, cells: [{ cell, value, formula? }] }] in tab order.
  function parseWorkbook(files) {
    const strings = [...(files["xl/sharedStrings.xml"] || "").matchAll(/<si>([\s\S]*?)<\/si>/g)].map((m) => [...m[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((t) => S.decodeEntities(t[1])).join(""));
    const rels = {};
    for (const m of (files["xl/_rels/workbook.xml.rels"] || "").matchAll(/<Relationship\b[^>]*>/g)) {
      const id = /Id="([^"]+)"/.exec(m[0]);
      const target = /Target="([^"]+)"/.exec(m[0]);
      if (id && target) rels[id[1]] = "xl/" + target[1].replace(/^\/?xl\//, "").replace(/^\//, "");
    }
    const sheets = [];
    for (const m of (files["xl/workbook.xml"] || "").matchAll(/<sheet\b[^>]*>/g)) {
      const name = S.decodeEntities((/name="([^"]*)"/.exec(m[0]) || [])[1] || "");
      const rid = (/r:id="([^"]+)"/.exec(m[0]) || [])[1];
      const xml = files[rels[rid]] || "";
      const cells = [];
      for (const c of xml.matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
        const ref = (/\br="([A-Z]+\d+)"/.exec(c[1]) || [])[1];
        if (!ref) continue;
        const type = (/\bt="(\w+)"/.exec(c[1]) || [])[1];
        const inner = c[2] || "";
        const f = /<f[^>]*>([\s\S]*?)<\/f>/.exec(inner);
        const v = /<v>([\s\S]*?)<\/v>/.exec(inner);
        const is = /<is>([\s\S]*?)<\/is>/.exec(inner);
        let value = v ? S.decodeEntities(v[1]) : is ? xmlText(is[1]) : "";
        if (type === "s" && v) value = strings[Number(v[1])] ?? "";
        if (type === "b") value = value === "1" ? "TRUE" : "FALSE";
        // Numbers as Sheets shows them: Google's xlsx writes 1200 as "1200.0".
        if (!type && /^-?\d+\.0+$/.test(value)) value = value.replace(/\.0+$/, "");
        if (value === "" && !f) continue;
        cells.push(f ? { cell: ref, value, formula: "=" + S.decodeEntities(f[1]) } : { cell: ref, value });
      }
      sheets.push({ name, cells });
    }
    return sheets;
  }

  // pptx parts -> [{ index, title, text: [paragraphs], notes }].
  function parseDeck(files) {
    const paragraphs = (xml) => [...xml.matchAll(/<a:p>([\s\S]*?)<\/a:p>/g)].map((p) => [...p[1].matchAll(/<a:t>([\s\S]*?)<\/a:t>/g)].map((t) => S.decodeEntities(t[1])).join("")).filter((x) => x.trim());
    const shapes = (xml) => [...xml.matchAll(/<p:sp>([\s\S]*?)<\/p:sp>/g)].map((m) => ({ type: (/<p:ph\b[^>]*type="(\w+)"/.exec(m[1]) || [])[1] || null, text: paragraphs(m[1]) }));
    const numbers = Object.keys(files).map((n) => (/^ppt\/slides\/slide(\d+)\.xml$/.exec(n) || [])[1]).filter(Boolean).map(Number).sort((a, b) => a - b);
    return numbers.map((n, i) => {
      const sh = shapes(files[`ppt/slides/slide${n}.xml`]);
      const titleShape = sh.find((s) => s.type === "title" || s.type === "ctrTitle");
      const rel = files[`ppt/slides/_rels/slide${n}.xml.rels`] || "";
      const notesTarget = (/Target="\.\.\/notesSlides\/(notesSlide\d+\.xml)"/.exec(rel) || [])[1];
      const notesXml = notesTarget ? files[`ppt/notesSlides/${notesTarget}`] || "" : "";
      const notes = shapes(notesXml).filter((s) => s.type !== "sldNum" && s.type !== "sldImg").flatMap((s) => s.text).join("\n");
      return { index: i + 1, title: titleShape ? titleShape.text.join(" ") : (sh[0] && sh[0].text[0]) || "", text: sh.flatMap((s) => s.text), notes };
    });
  }

  const SIGN_IN = [/^https:\/\/accounts\.google\.com\//, /^https:\/\/workspace\.google\.com\//];

  function create(t) {
    const g = S.shared.google;
    const editors = {
      colName,
      colIndex,
      // Unzipped export parts of a file (xlsx or pptx). The export
      // redirects to a googleusercontent host without CORS headers, so the
      // session's fetch downloads it and a blank tab unzips it.
      async exportParts(name, ref, format, want) {
        const { response } = await g.fetchFile(t, name, g.exportURL(ref, format, name));
        const base64 = t.Buffer.from(await response.arrayBuffer()).toString("base64");
        const r = await t.withTab("about:blank", (page) => page.evaluate(unzipExport, { base64, want }));
        if (!r.files) throw new S.SiteError("unexpected", `${name}: ${r.error || "the export could not be read"}`);
        return r.files;
      },
      async workbook(name, ref) {
        return parseWorkbook(await editors.exportParts(name, ref, "xlsx", "^xl/(workbook\\.xml|_rels/workbook\\.xml\\.rels|sharedStrings\\.xml|worksheets/[^/]+\\.xml)$"));
      },
      async deck(name, ref) {
        return parseDeck(await editors.exportParts(name, ref, "pptx", "^ppt/(slides|notesSlides)/(_rels/)?[^/]+\\.xml(\\.rels)?$"));
      },
      editURL(ref) {
        const q = ref.uid !== undefined ? `?authuser=${ref.uid}` : "";
        return `https://docs.google.com/${ref.kind}/d/${ref.id}/edit${q}${ref.gid !== undefined && ref.gid !== null ? `#gid=${ref.gid}` : ""}`;
      },
      async waitEditor(name, page) {
        await t.waitIn(page, () => !!document.querySelector(".docs-title-input, #docs-titlebar"), undefined, { signIn: SIGN_IN, name, what: "the editor", timeout: 45000 });
      },
      // Runs body(page) in the file's editor in a background tab.
      async inEditor(name, ref, body) {
        return t.withTab(editors.editURL(ref), async (page) => {
          await editors.waitEditor(name, page);
          return body(page);
        });
      },
      // Reloads the editor and fails (sharing_changed) unless its Share
      // button still says `expected`: sharing can change after the label
      // that decided between an immediate edit and a draft, or after a
      // draft's preview. Each write calls it right before its first input.
      async recheckSharing(name, page, expected, when) {
        await page.reload({ waitUntil: "load", timeout: 45000 });
        await editors.waitEditor(name, page);
        const now = await editors.sharing(page);
        if (now !== expected) throw new S.SiteError("sharing_changed", `${name}: the file's sharing is now "${now || "unknown"}", not "${expected || "unknown"}" as ${when}; nothing was changed. Make a new ${when === "previewed" ? "draft and show it to the user again" : "call"}`);
      },
      // The Share button's description: "Share. Private to only me" and the like.
      // The button renders a moment after the editor; wait for it.
      async sharing(page) {
        const label = await t.waitIn(page, () => {
          // The first element whose label describes sharing (the id sits on an unlabeled wrapper).
          for (const b of document.querySelectorAll("#docs-titlebar-share-client-button, #docs-titlebar-share-client-button *, [aria-label^='Share'], [data-tooltip^='Share']")) {
            const label = (b.getAttribute("aria-label") || b.getAttribute("data-tooltip") || "").trim();
            if (/^Share\. /.test(label)) return label;
          }
          return null;
        }, undefined, { timeout: 15000, what: "the Share button" }).catch(() => "");
        return label || "";
      },
      isPrivate: (label) => /private to only me/i.test(label),
      // A write: at once on a private file, else a draft confirmed later.
      // spec(label, page) (may be async) -> { summary, preview, run(page,
      // gate) }. run calls gate() right before its first input to the
      // file: it reloads the editor and requires the sharing label this
      // decision (or the preview) was made on.
      edit(site, action, name, ref, input, options, spec) {
        if (typeof input === "string" && /^draft-\d+-[0-9a-f]+$/.test(input)) return t.write(site, action, input, options);
        return editors.inEditor(name, ref, async (page) => {
          const label = await editors.sharing(page);
          const title = await page.evaluate(() => { const i = document.querySelector(".docs-title-input"); return i ? i.value : null; });
          const s = await spec(label, page);
          if (editors.isPrivate(label)) return s.run(page, () => editors.recheckSharing(name, page, label, "when the edit started"));
          return t.write(site, action, { draft: true }, undefined, () => ({
            category: "[9] edit content others can see",
            summary: s.summary,
            preview: { ...s.preview, title, sharing: label || "unknown" },
            run: () => editors.inEditor(name, ref, (p) => s.run(p, () => editors.recheckSharing(name, p, label, "previewed"))),
          }));
        });
      },
      // Find and replace (Meta+Shift+H) in Docs or Slides: replaces every match.
      async findReplace(page, find, replacement) {
        await page.keyboard.press("Meta+Shift+H");
        const dialog = page.locator('[role="dialog"]').filter({ hasText: "Replace all" }).first();
        // In Slides the shortcut does nothing while the filmstrip has focus: use Edit > Find and replace.
        const opened = await dialog.waitFor({ timeout: 3000 }).then(() => true, () => false);
        if (!opened) {
          await page.locator("#docs-edit-menu").click();
          await page.getByRole("menuitem", { name: /^Find and replace/ }).first().click();
          await dialog.waitFor({ timeout: 15000 });
        }
        const inputs = dialog.locator('input[type="text"], input:not([type])');
        await inputs.nth(0).fill(find);
        await inputs.nth(1).fill(replacement);
        await dialog.getByRole("button", { name: "Replace all" }).click();
        await t.sleep(500);
        await page.keyboard.press("Escape").catch(() => {});
      },
      // Waits until the editor no longer says it is saving (its save
      // indicator), so exports include the edit.
      async saved(page) {
        await t.sleep(400);
        await t.waitIn(page, () => { const b = document.querySelector("#docs-save-indicator-badge, .docs-save-indicator-badge"); return !b || !/Saving/i.test(b.textContent || b.getAttribute("aria-label") || ""); }, undefined, { timeout: 20000, what: "the editor to save" }).catch(() => {});
      },
      // Checks the edit through an export, backing off (exports are rate-limited).
      async verify(check, waits = [800, 1500, 2500, 4000, 6000, 8000]) {
        for (const wait of waits) {
          await t.sleep(wait);
          try {
            if (await check()) return true;
          } catch (e) {}
        }
        return false;
      },
    };
    return editors;
  }

  S.shared.editors = { create, parseWorkbook, parseDeck, unzipExport };
})(typeof globalThis !== "undefined" ? globalThis : this);
