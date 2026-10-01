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
        // Exports a Docs/Sheets/Slides file given by any Drive or Docs URL; { path, title, format }.
        async export(file, options = {}) {
          const ref = g.parse(file, "googleDrive.export", options.kind);
          if (ref.kind === "file") throw new S.SiteError("invalid", "googleDrive.export: this is an uploaded Drive file; use googleDrive.download(), or pass { kind: \"document\" | \"spreadsheets\" | \"presentation\" } for a Google file opened by id");
          if (options.uid !== undefined) ref.uid = options.uid;
          return g.exportTo(t, "googleDrive.export", ref, options.format || g.FORMATS[ref.kind][0], options);
        },
      };
    },
    { summary: "Download Drive files; export Google files found by Drive URL" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
