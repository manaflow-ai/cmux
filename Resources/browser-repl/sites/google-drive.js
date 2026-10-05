// sites.googleDrive: download Drive files and export Google files by URL,
// through Google's download and export endpoints in the signed-in session.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL, URLSearchParams } = root.CmuxBrowserRepl.core;
  S.register(
    "googleDrive",
    (t) => {
      const g = S.shared.google;
      const ed = S.shared.editors.create(t);
      // Moves the file open in `page` (its editor) to the trash.
      async function trashIn(page, ref) {
        await t.waitIn(page, () => !!document.querySelector("#docs-file-menu"), undefined, { signIn: [/^https:\/\/accounts\.google\.com\//], name: "googleDrive.trash", what: "the editor's File menu", timeout: 45000 });
        await t.sleep(1500);
        // File > Move to trash (matched by the item's text; retried once if the menu did not open).
        const item = page.locator('[role="menuitem"]').filter({ hasText: /^(Move to trash|Move to bin)/ }).first();
        for (let attempt = 0; ; attempt++) {
          await page.locator("#docs-file-menu").click();
          if (await item.waitFor({ timeout: 5000 }).then(() => true, () => false)) break;
          if (attempt) throw new S.SiteError("timeout", "googleDrive.trash: the File menu has no Move to trash item");
          await page.keyboard.press("Escape").catch(() => {});
          await t.sleep(1500);
        }
        await item.click();
        await t.waitIn(page, () => /moved to (the )?(trash|bin)|in (the )?(trash|bin)/i.test(document.body.innerText), undefined, { name: "googleDrive.trash", what: "the trash confirmation", timeout: 15000 }).catch(() => {});
        // A trashed file still opens for its owner, with "File is in trash".
        return t.withTab(ed.editURL(ref), async (check) => {
          const verified = await t.waitIn(check, () => /\b(is|moved to) (in )?(the )?(trash|bin)\b/i.test(document.body.innerText), undefined, { timeout: 20000, what: "the trash notice" }).then(() => true, () => false);
          return { status: "trashed", verified };
        });
      }
      // Rows of a Drive list view (Recent, search) in a background tab.
      async function driveRows(name, view, options) {
        const uid = options.uid === undefined ? 0 : options.uid;
        if (!Number.isInteger(uid) || uid < 0) throw new S.SiteError("invalid", `${name}: uid: expected a non-negative integer, got ${JSON.stringify(options.uid)}`);
        const SIGN_IN = [/^https:\/\/accounts\.google\.com\//, /^https:\/\/workspace\.google\.com\//, /\/drive\/about/];
        return t.withTab(`https://drive.google.com/drive/u/${uid}/${view}`, async (page) => {
          await t.waitIn(page, () => !!document.querySelector('[role="row"][data-id], [data-id][role="gridcell"], [data-id] [role="gridcell"]') || /No files|Nothing in Recent|Files you open|No results/i.test(document.body.innerText), undefined, { signIn: SIGN_IN, name, what: "the Drive list", timeout: 30000 });
            const rows = await page.evaluate((limit) => {
              const clean = (x) => (x || "").replace(/\s+/g, " ").trim();
              const out = [];
              const seen = new Set();
              for (const el of document.querySelectorAll("[data-id]")) {
                const id = el.getAttribute("data-id");
                if (!/^[\w-]{25,}$/.test(id) || seen.has(id) || !el.querySelector('[role="gridcell"]') && el.getAttribute("role") !== "row") continue;
                seen.add(id);
                // The row's tooltip is "<name> <type>"; the type is one of Drive's labels.
                const TYPES = ["Google Docs", "Google Sheets", "Google Slides", "Google Forms", "Google Drawings", "Google Sites", "Google Apps Script", "Shared folder", "Folder", "PDF", "Image", "Video", "Audio", "Microsoft Word", "Microsoft Excel", "Microsoft PowerPoint", "Text", "Archive", "Unknown"];
                const tip = clean((el.querySelector("[data-tooltip]") || {}).getAttribute ? el.querySelector("[data-tooltip]").getAttribute("data-tooltip") : "");
                const type = TYPES.find((x) => tip === x || tip.endsWith(" " + x)) || null;
                let title = type ? clean(tip.slice(0, tip.length - type.length)) : tip;
                if (!title) title = clean((el.innerText || "").split("\n")[0]);
                out.push({ id, title, type, url: "https://drive.google.com/open?id=" + id });
                if (out.length >= limit) break;
              }
              return out;
            }, options.limit || 50);
            return rows;
          });
      }

      return {
        // Downloads an uploaded file (PDF, image, zip, ...) by Drive URL or id; { path, title, contentType }.
        async download(file, options = {}) {
          const ref = g.parse(file, "googleDrive.download");
          if (ref.kind && ref.kind !== "file") return g.exportTo(t, "googleDrive.download", ref, options.format || g.FORMATS[ref.kind][0], options);
          const q = new URLSearchParams({ id: ref.id, export: "download", confirm: "t" });
          const uid = options.uid !== undefined ? options.uid : ref.uid;
          if (uid !== undefined) q.set("authuser", String(uid));
          const { response, title, contentType } = await g.fetchFile(t, "googleDrive.download", `https://drive.usercontent.google.com/download?${q}`);
          const fname = g.dispositionName(response.headers.get("content-disposition"));
          const ext = fname && /\.[a-z0-9]{1,8}$/i.test(fname) ? /\.[a-z0-9]{1,8}$/i.exec(fname)[0] : "";
          const file_ = t.outputPath(options, ext, title || `drive-${ref.id}`);
          t.fs.writeFileSync(file_, t.Buffer.from(await response.arrayBuffer()));
          return { path: file_, title, contentType };
        },
        // Files in Drive's Recent view: [{ id, title, type, url }] (the view
        // in a background tab; rows carry the file id as data-id).
        recent(options = {}) {
          return driveRows("googleDrive.recent", "recent", options);
        },
        // Drive search with its operators ("type:spreadsheet owner:me",
        // "budget"), the same rows as recent().
        search(query, options = {}) {
          if (typeof query !== "string" || !query.trim()) throw new S.SiteError("invalid", `googleDrive.search: query: expected Drive search text, got ${JSON.stringify(query)}`);
          return driveRows("googleDrive.search", `search?q=${encodeURIComponent(query)}`, options);
        },
        // Creates a private Google file and names it: create("spreadsheets" | "document" | "presentation", title, { uid })
        // -> { id, url, title, account }. The new file is private to the
        // account, so this is not a draft (nobody else sees it).
        async create(kind, title, options = {}) {
          if (!["document", "spreadsheets", "presentation"].includes(kind)) throw new S.SiteError("invalid", `googleDrive.create: kind: expected document, spreadsheets or presentation, got ${JSON.stringify(kind)}`);
          if (typeof title !== "string" || !title.trim()) throw new S.SiteError("invalid", "googleDrive.create: title: expected a name");
          const uid = options.uid === undefined ? 0 : options.uid;
          if (!Number.isInteger(uid) || uid < 0) throw new S.SiteError("invalid", `googleDrive.create: uid: expected a non-negative integer, got ${JSON.stringify(options.uid)}`);
          // Loading /create makes the file, as the account authuser names.
          // The /u/ index is positional (another session's sign-in moves
          // accounts to other indexes), so the URL names the account by the
          // email at that index now, which Google accepts as authuser.
          const account = (await g.accountAt(t, "googleDrive.create", uid)).email;
          return t.withTab(`https://docs.google.com/${kind}/create?${new URLSearchParams({ authuser: account })}`, async (page) => {
            await t.waitIn(page, () => /\/d\/[\w-]+\/edit/.test(location.pathname) && !!document.querySelector(".docs-title-input"), undefined, { signIn: [/^https:\/\/accounts\.google\.com\//], name: "googleDrive.create", what: "the new file's editor", timeout: 45000 });
            const id = /\/d\/([\w-]+)\//.exec(new URL(page.url()).pathname)[1];
            // A rename typed while the editor loads is lost: rename once it
            // settles, then confirm through the tab title, retrying.
            const input = page.locator(".docs-title-input").first();
            let renamed = false;
            for (let attempt = 0; attempt < 4 && !renamed; attempt++) {
              await t.sleep(attempt ? 1500 : 1500);
              await input.click();
              await input.fill(title);
              await input.press("Enter");
              renamed = await t.waitIn(page, (want) => document.title.startsWith(want + " - "), title, { timeout: 3000, what: "the new title" }).then(() => true, () => false);
            }
            if (!renamed) throw new S.SiteError("rename_failed", `googleDrive.create: created ${kind} ${id} but could not name it`);
            // The tab title changes before the rename is saved: keep the tab
            // until the file's export carries the new name.
            const ref = { kind, id, uid: options.uid };
            let saved = false;
            for (const wait of [1000, 2000, 3000, 5000, 8000]) {
              await t.sleep(wait);
              try {
                // A Sheets CSV export is named "<title> - <tab>".
                const got = (await g.exportText(t, "googleDrive.create", ref, kind === "spreadsheets" ? "csv" : "txt")).title || "";
                if (got === title || (kind === "spreadsheets" && got.startsWith(title + " - "))) {
                  saved = true;
                  break;
                }
              } catch (e) {}
            }
            if (!saved) throw new S.SiteError("rename_failed", `googleDrive.create: created ${kind} ${id} but its new name did not save`);
            return { id, url: `https://docs.google.com/${kind}/d/${id}/edit`, title, account };
          });
        },
        // Moves a Google file to the trash through its editor's File menu:
        // a draft (deleting data, [1]) that shows the file, its sharing and
        // the account; trash(draftId, { confirm: true }) reads all of it
        // back in a fresh editor right before the File menu.
        trash(file, options) {
          const name = "googleDrive.trash";
          if ((typeof file === "string" && /^draft-\d+-[0-9a-f]+$/.test(file)) || (options && options.confirm)) return t.write("googleDrive", "trash", file, options);
          const input = S.copyInput(file, `sites.${name}`);
          const ref = g.parse(input, name);
          if (!g.FORMATS[ref.kind]) throw new S.SiteError("invalid", `${name}: expected a Google Docs, Sheets or Slides URL`);
          return ed.edit("googleDrive", "trash", name, ref, {}, undefined, async (page) => {
            const title = await page.evaluate(() => { const i = document.querySelector(".docs-title-input"); return i ? i.value : null; });
            return {
              category: "[1] delete data",
              summary: `Move Google file ${ref.id}${title ? ` ("${title}")` : ""} to the trash`,
              observe: async () => ({}),
              act: (p) => trashIn(p, ref),
            };
          });
        },
        // Exports a Docs/Sheets/Slides file given by any Drive or Docs URL; { path, title, format }.
        async export(file, options = {}) {
          const ref = g.parse(file, "googleDrive.export", options.kind);
          if (ref.kind === "file") throw new S.SiteError("invalid", "googleDrive.export: this is an uploaded Drive file; use googleDrive.download(), or pass { kind: \"document\" | \"spreadsheets\" | \"presentation\" } for a Google file opened by id");
          if (options.uid !== undefined) ref.uid = options.uid;
          return g.exportTo(t, "googleDrive.export", ref, options.format || g.FORMATS[ref.kind][0], options);
        },
      };
    },
    { summary: "Download Drive files; export Google files found by Drive URL; create private files; confirmed-draft trash", writes: ["trash"] },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
