// Shared editing helpers for Google Docs, Sheets and Slides
// (docs/browser-repl/site-tools.md, "Editing Google files"). Reads go through
// the editors' own export endpoints in the signed-in session; xlsx and pptx
// exports are unzipped in a docs.google.com page with the browser's
// DecompressionStream. Writes drive the editor in a background tab with real
// input: the Sheets name box and a paste from cmux's per-tab clipboard, the
// Docs and Slides Find and replace dialog, typing at the end of a document.
//
// Rule for writes: every edit is a draft first (reference B's confirmation
// taxonomy, [9]: edits others can see). The Share button's label is page
// text, so it never decides that a file is private enough to skip the
// draft; the draft shows it, and the confirmation requires it again.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL } = root.CmuxBrowserRepl.core;

  // Runs in a blank page (for DecompressionStream): unzips base64 bytes and
  // returns the text of entries whose names match arg.want. A shared file's
  // export is untrusted, so the ZIP is bounded (docs/browser-repl/
  // site-tools.md, "Editing Google files"): at most arg.limits.entries
  // entries; every central and local header, name and data range inside the
  // archive; a wanted entry decompresses to at most its declared size and
  // arg.limits.entryBytes, and all wanted entries to arg.limits.totalBytes
  // together. Compressed input goes in 16 KiB at a time (deflate expands
  // at most about 1,032 times, so one burst is at most about 16.5 MiB) and
  // the stream is cancelled the moment output passes a limit. A limit
  // returns code "limit"; a malformed archive "unexpected".
  async function unzipExport(arg) {
    const lim = arg.limits;
    const fail = (code, error) => ({ status: 200, code, error });
    const bin = atob(arg.base64);
    const buf = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
    const view = new DataView(buf.buffer);
    const bad = (what) => fail("unexpected", `the export is not a valid zip file (${what})`);
    let eocd = -1;
    for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65557); i--) if (view.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
    if (eocd < 0) return fail("unexpected", "the export is not a zip file");
    const count = view.getUint16(eocd + 10, true);
    if (count > lim.entries) return fail("limit", `the export holds ${count} entries; the reader reads at most ${lim.entries}`);
    const cdStart = view.getUint32(eocd + 16, true);
    if (cdStart > eocd) return bad("central directory outside the archive");
    let p = cdStart;
    const want = new RegExp(arg.want);
    const out = {};
    const dec = new TextDecoder();
    let total = 0;
    for (let n = 0; n < count; n++) {
      if (p + 46 > eocd || view.getUint32(p, true) !== 0x02014b50) return bad(`central header ${n}`);
      const flags = view.getUint16(p + 8, true);
      const method = view.getUint16(p + 10, true);
      const size = view.getUint32(p + 20, true);
      const declared = view.getUint32(p + 24, true);
      const nameLen = view.getUint16(p + 28, true);
      const extraLen = view.getUint16(p + 30, true);
      const commentLen = view.getUint16(p + 32, true);
      const local = view.getUint32(p + 42, true);
      if (p + 46 + nameLen + extraLen + commentLen > eocd) return bad(`central header ${n}`);
      const name = dec.decode(buf.subarray(p + 46, p + 46 + nameLen));
      p += 46 + nameLen + extraLen + commentLen;
      if (!want.test(name)) continue;
      if (flags & 1) return bad(`${name} is encrypted`);
      if (local + 30 > cdStart || view.getUint32(local, true) !== 0x04034b50) return bad(`local header of ${name}`);
      const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
      if (start + size > cdStart) return bad(`data of ${name}`);
      if (declared > lim.entryBytes) return fail("limit", `${name} declares ${declared} bytes; the reader decompresses at most ${lim.entryBytes} bytes per entry`);
      if (total + declared > lim.totalBytes) return fail("limit", `the export's entries decompress past ${lim.totalBytes} bytes together; the reader decompresses at most that`);
      const data = buf.subarray(start, start + size);
      let bytes;
      if (method === 0) {
        bytes = data;
      } else if (method === 8) {
        const input = new ReadableStream({
          offset: 0,
          pull(controller) {
            if (this.offset >= data.length) return controller.close();
            controller.enqueue(data.slice(this.offset, this.offset + 16384));
            this.offset += 16384;
          },
        }, { highWaterMark: 0 });
        const reader = input.pipeThrough(new DecompressionStream("deflate-raw")).getReader();
        const chunks = [];
        let got = 0;
        try {
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            got += value.length;
            if (got > declared) {
              reader.cancel().catch(() => {});
              return fail("limit", `${name} decompresses past its declared size of ${declared} bytes`);
            }
            chunks.push(value);
          }
        } catch (e) {
          return bad(`${name}: ${e && e.message}`);
        }
        bytes = new Uint8Array(got);
        let at = 0;
        for (const c of chunks) { bytes.set(c, at); at += c.length; }
      } else {
        return bad(`${name} uses compression method ${method}`);
      }
      if (bytes.length !== declared) return fail("unexpected", `the export is not a valid zip file (${name} declares ${declared} bytes but holds ${bytes.length})`);
      total += bytes.length;
      out[name] = dec.decode(bytes);
    }
    return { status: 200, files: out };
  }

  // Bounds of unzipExport. The total matches the 64 MiB a driver result may
  // carry (driver-protocol.md, driverCall), which the unzipped text returns
  // through; one entry may take half of it.
  const UNZIP_LIMITS = Object.freeze({ entries: 10000, entryBytes: 32 * 1024 * 1024, totalBytes: 64 * 1024 * 1024 });

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
        const r = await t.withTab("about:blank", (page) => page.evaluate(unzipExport, { base64, want, limits: UNZIP_LIMITS }));
        if (!r.files) throw new S.SiteError(r.code === "limit" ? "limit" : "unexpected", `${name}: ${r.error || "the export could not be read"}`);
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
      // The Share button's description: "Share. Private to only me" and the
      // like, or "" when it is unknown. A draft shows it and its commit
      // requires it again, so it is read only from the editor's own Share button: the one
      // element with its id in the document, inside the editor's title bar
      // (the id sits on an unlabeled wrapper, the label on the button in
      // it), through locators (the agent's isolated world). Every sharing
      // label there must agree; another label anywhere else in the page
      // counts for nothing, and two that disagree make it unknown. The
      // button renders a moment after the editor; wait for it.
      async sharing(page) {
        const SHARE_LABEL = /^Share\. /;
        const read = async () => {
          if ((await page.locator("#docs-titlebar-share-client-button").count()) !== 1) return null;
          // In the editor's header (the title bar, or the header around it).
          const button = page.locator(":is(#docs-titlebar, #docs-header) #docs-titlebar-share-client-button").first();
          if (!(await button.count())) return null;
          const labelOf = async (l) => ((await l.getAttribute("aria-label", { timeout: 2000 })) || (await l.getAttribute("data-tooltip", { timeout: 2000 })) || "").trim();
          const labels = new Set();
          const own = await labelOf(button);
          if (SHARE_LABEL.test(own)) labels.add(own);
          const inner = button.locator("[aria-label^='Share'], [data-tooltip^='Share']");
          const n = await inner.count();
          if (n > 8) return "";
          for (let i = 0; i < n; i++) {
            const label = await labelOf(inner.nth(i));
            if (SHARE_LABEL.test(label)) labels.add(label);
          }
          if (!labels.size) return null;
          return labels.size === 1 ? [...labels][0] : "";
        };
        const deadline = t.now() + 15000;
        for (;;) {
          const label = await read().catch(() => null);
          if (label !== null) return label;
          if (t.now() >= deadline) return "";
          await t.sleep(150);
        }
      },
      // Offsets of `find` in `text` as the editors' Find and replace
      // matches it by default: case ignored, no overlaps.
      matchesIn(text, find) {
        const re = new RegExp(String(find).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi");
        return [...String(text).matchAll(re)].map((m) => m.index);
      },
      // What a commit reads back in the file's editor right before the
      // write: the file (its id in the editor's URL), its title, its
      // sharing and the account the editor acts as (observeAccount).
      async observe(name, ref, page) {
        let fileId;
        try {
          fileId = (/\/d\/([\w-]+)\//.exec(new URL(page.url()).pathname) || [])[1];
        } catch (e) {}
        const title = await t.readBack(page, () => { const i = document.querySelector(".docs-title-input"); return i ? i.value : null; }).catch(() => null);
        const label = await editors.sharing(page);
        const who = await g.observeAccount(t, name, page, ref.uid);
        return { fileId, title: typeof title === "string" ? title : undefined, sharing: label || undefined, account: who.accountEmail, accountId: who.accountId };
      },
      // A write to a Google file, always as a draft (sites.<site>.<action>
      // in the loader's commit protocol). spec(page) (may be async), in the
      // file's editor at draft time -> { summary, target, content, sent,
      // canon, observe(page), act(page) }. The draft binds the account the
      // editor acts as (email and Google's account id), the file (id,
      // title, sharing) and the spec's target and content; the commit opens
      // the editor again, reads all of it back (observe() and
      // spec.observe(page)) and only then runs spec.act(page, press).
      // spec.act changes the file only through press(locator) (a menu
      // item or button) or press.input(fn) (keys or a paste): each reads
      // the editor's account again right before it, so an account another
      // session switched to after the read-back edits nothing.
      edit(site, action, name, ref, input, options, spec) {
        if (typeof input === "string" && /^draft-\d+-[0-9a-f]+$/.test(input)) return t.write(site, action, input, options);
        if (options && options.confirm) return t.write(site, action, { draft: true }, options);
        return t.write(site, action, { draft: true }, undefined, () =>
          editors.inEditor(name, ref, async (page) => {
            const now = await editors.observe(name, ref, page);
            if (!now.sharing) throw new S.SiteError("target_unverified", `${name}: could not read the file's sharing from its Share button; nothing was drafted`);
            if (!now.account || !now.accountId || !/^[^\s()]+@[^\s()]+$/.test(now.account)) throw new S.SiteError("account_unverified", `${name}: could not tell which Google account the editor acts as (its header and Google's account list must agree); nothing was drafted`);
            if (!now.fileId || now.fileId !== ref.id) throw new S.SiteError("target_unverified", `${name}: the editor opened ${now.fileId || "no file"}, not ${ref.id}; nothing was drafted`);
            const s = await spec(page);
            return {
              category: s.category || "[9] edit content others can see",
              summary: `${s.summary} as ${now.account}`,
              account: { account: now.account, accountId: now.accountId },
              target: { fileId: ref.id, title: now.title === undefined ? null : now.title, sharing: now.sharing, ...(s.target || {}) },
              content: s.content || {},
              sent: s.sent,
              canon: s.canon,
              commit: (c) =>
                editors.inEditor(name, ref, (p) => {
                  const account = async () => {
                    const who = await g.observeAccount(t, name, p, ref.uid);
                    return { account: who.accountEmail, accountId: who.accountId };
                  };
                  return c.write(async () => ({ ...(await editors.observe(name, ref, p)), ...(await s.observe(p)) }), (press) => s.act(p, press), { account, inputs: "guarded" });
                }),
            };
          }),
        );
      },
      // Find and replace (Meta+Shift+H) in Docs or Slides: replaces every
      // match. `press`: a commit's press (Replace all is the write).
      async findReplace(page, find, replacement, press) {
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
        const replaceAll = dialog.getByRole("button", { name: "Replace all" });
        if (press) await press(replaceAll);
        else await replaceAll.click();
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
