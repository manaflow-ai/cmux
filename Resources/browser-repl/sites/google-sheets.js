// sites.googleSheets: sheet list, cell values and exports through Google's
// htmlview and export endpoints in the signed-in session (no tab). Values are
// the full sheet as Google exports it (not the first HTML chunk).
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  S.register(
    "googleSheets",
    (t) => {
      const g = S.shared.google;
      const ref = (sheet, name, options) => {
        const r = g.parse(sheet, name, "spreadsheets");
        if (options.uid !== undefined) r.uid = options.uid;
        return r;
      };
      const api = {
        // { title, sheets: [{ name, gid }] }
        async info(sheet, options = {}) {
          const r = ref(sheet, "googleSheets.info", options);
          const q = r.uid !== undefined ? `?authuser=${r.uid}` : "";
          const { response } = await g.fetchFile(t, "googleSheets.info", `https://docs.google.com/spreadsheets/d/${r.id}/htmlview${q}`, { expectHTML: true });
          const html = await response.text();
          const titleMatch = /<title>([^<]*)<\/title>/i.exec(html);
          const title = titleMatch ? S.decodeEntities(titleMatch[1]).replace(/\s+-\s+Google (Sheets|Drive)\s*$/, "").trim() : null;
          const sheets = [];
          const re = /id="sheet-button-(\d+)"[^>]*>\s*(?:<a[^>]*>)?([^<]*)</g;
          for (let m; (m = re.exec(html)); ) sheets.push({ name: S.decodeEntities(m[2]).trim(), gid: m[1] });
          return { title, sheets: sheets.length ? sheets : [{ name: null, gid: "0" }] };
        },
        // { title, sheet, gid, rows: string[][] }. Pick the sheet with
        // { gid } or { sheet: name } (default: the URL's gid, else the first);
        // { range: "A1:C10" } keeps that block.
        async read(sheet, options = {}) {
          const r = ref(sheet, "googleSheets.read", options);
          let name = null;
          if (options.gid !== undefined) r.gid = String(options.gid);
          else if (options.sheet !== undefined) {
            const info = await api.info(sheet, options);
            const found = info.sheets.find((s) => s.name === options.sheet);
            if (!found) throw new S.SiteError("not_found", `googleSheets.read: no sheet named ${JSON.stringify(options.sheet)}; sheets: ${info.sheets.map((s) => s.name).join(", ")}`);
            r.gid = found.gid;
            name = found.name;
          }
          const { title, text } = await g.exportText(t, "googleSheets.read", r, "csv");
          let rows = S.parseCSV(text);
          if (options.range) {
            const { c0, r0, c1, r1 } = S.parseA1Range(options.range);
            rows = rows.slice(r0, r1 === null ? undefined : r1 + 1).map((row) => row.slice(c0, c1 === null ? undefined : c1 + 1));
          }
          return { title, sheet: name, gid: r.gid === undefined ? null : String(r.gid), rows };
        },
        // Every sheet: [{ name, gid, rows }].
        async readAll(sheet, options = {}) {
          const info = await api.info(sheet, options);
          const out = [];
          for (const s of info.sheets) {
            const { rows } = await api.read(sheet, { ...options, gid: s.gid, sheet: undefined });
            out.push({ name: s.name, gid: s.gid, rows });
          }
          return out;
        },
        // Writes xlsx (all sheets), csv/tsv (one sheet: { gid }), pdf or ods; { path, title, format }.
        async export(sheet, options = {}) {
          const r = ref(sheet, "googleSheets.export", options);
          if (options.gid !== undefined) r.gid = String(options.gid);
          return g.exportTo(t, "googleSheets.export", r, options.format || "xlsx", options);
        },
      };
      return api;
    },
    { summary: "Sheet list, cell values (whole sheet or A1 range) and exports of Google Sheets" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
