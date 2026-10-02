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
      const ed = S.shared.editors.create(t);
      // Selects a range with the name box, as a person would.
      async function selectRange(page, range) {
        const box = page.locator("#t-name-box");
        await box.waitFor({ timeout: 30000 });
        await box.click();
        await box.fill(range);
        await box.press("Enter");
        await t.sleep(300);
      }
      function writeCells(action, sheet, range, values, options) {
        const name = `googleSheets.${action}`;
        if (typeof sheet === "string" && /^draft-\d+-[0-9a-f]+$/.test(sheet)) return ed.edit("googleSheets", action, name, null, sheet, range);
        if (!Array.isArray(values) || !values.length || !values.every(Array.isArray)) throw new S.SiteError("invalid", `${name}: values: expected rows, an array of arrays such as [["a", 1]]`);
        const r = ref(sheet, name, options || {});
        const start = String(range).split(":")[0].toUpperCase();
        const m = /^([A-Z]+)(\d+)$/.exec(start);
        if (!m) throw new S.SiteError("invalid", `${name}: range: expected A1 notation, got ${JSON.stringify(range)}`);
        const c0 = ed.colIndex(m[1]);
        const r0 = Number(m[2]);
        const width = Math.max(...values.map((row) => row.length));
        const target = `${start}:${ed.colName(c0 + width - 1)}${r0 + values.length - 1}`;
        if (values.some((row) => row.some((v) => /[\n\t]/.test(String(v === null || v === undefined ? "" : v))))) throw new S.SiteError("invalid", `${name}: a value contains a tab or a line break; Sheets cells are typed and cannot hold one this way`);
        const rowOps = [];
        return ed.edit("googleSheets", action, name, r, { range: target }, options, () => ({
          summary: `Write ${values.length} row(s) at ${target} in Google Sheet ${r.id}`,
          preview: { file: sheet, range: target, values },
          run: async (page) => {
            const want = new Map();
            values.forEach((row, i) => row.forEach((v, j) => want.set(`${ed.colName(c0 + j)}${r0 + i}`, v === null || v === undefined ? "" : String(v))));
            const check = async () => {
              const got = new Map((await api.cells(sheet, { ...(options || {}), range: target })).cells.map((c) => [c.cell, c]));
              return [...want].every(([cell, v]) => v === "" || (got.has(cell) && (v.startsWith("=") ? got.get(cell).formula === v : got.get(cell).value === v)));
            };
            // One paste of the rows as TSV at the top-left cell, as a person
            // pastes a range: Sheets reads the paste event's clipboardData.
            await selectRange(page, start);
            await page.clipboard.writeText(values.map((row) => row.map((v) => (v === null || v === undefined ? "" : String(v))).join("\t")).join("\n"));
            await page.keyboard.press("ControlOrMeta+v");
            await ed.saved(page);
            if (await ed.verify(check, [800, 1500, 2500])) return { status: "written", range: target, verified: true };
            // An editor that dropped the paste gets typed keys, cell by cell
            // (Tab moves right, Enter starts the next row).
            await selectRange(page, start);
            for (const row of values) {
              row.forEach((v, j) => {
                rowOps.push([String(v === null || v === undefined ? "" : v), j < row.length - 1]);
              });
              for (const [text, tab] of rowOps.splice(0)) {
                if (text) await page.keyboard.type(text);
                if (tab) await page.keyboard.press("Tab");
              }
              await page.keyboard.press("Enter");
            }
            await ed.saved(page);
            return { status: "written", range: target, verified: await ed.verify(check) };
          },
        }));
      }
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
        // Cells with values and formulas from the xlsx export:
        // { sheet, range, cells: [{ cell, value, formula? }] }. Pick the tab
        // with { sheet: name } or { gid } (default: the URL's gid, else the
        // first); { range: "A1:C10" } keeps that block.
        async cells(sheet, options = {}) {
          const r = ref(sheet, "googleSheets.cells", options);
          const book = await ed.workbook("googleSheets.cells", r);
          let tab = book[0];
          if (options.sheet !== undefined) tab = book.find((x) => x.name === options.sheet);
          else if (options.gid !== undefined || r.gid !== undefined) {
            const gid = String(options.gid !== undefined ? options.gid : r.gid);
            const info = await api.info(sheet, options);
            const at = info.sheets.findIndex((x) => x.gid === gid);
            tab = at >= 0 ? book[at] : tab;
          }
          if (!tab) throw new S.SiteError("not_found", `googleSheets.cells: no sheet named ${JSON.stringify(options.sheet)}; sheets: ${book.map((x) => x.name).join(", ")}`);
          let cells = tab.cells;
          if (options.range) {
            const { c0, r0, c1, r1 } = S.parseA1Range(options.range);
            cells = cells.filter((c) => {
              const m = /^([A-Z]+)(\d+)$/.exec(c.cell);
              const col = ed.colIndex(m[1]);
              const row = Number(m[2]) - 1;
              return col >= c0 && (c1 === null || col <= c1) && row >= r0 && (r1 === null || row <= r1);
            });
          }
          return { sheet: tab.name, range: options.range || null, cells };
        },
        // Cells whose value contains `text`, in every tab: [{ sheet, cell, value }].
        async find(sheet, text, options = {}) {
          const r = ref(sheet, "googleSheets.find", options);
          const book = await ed.workbook("googleSheets.find", r);
          const hits = [];
          for (const tab of book) for (const c of tab.cells) if (String(c.value).includes(String(text)) || (c.formula && c.formula.includes(String(text)))) hits.push({ sheet: tab.name, cell: c.cell, value: c.value });
          return hits.sort((a, b) => (a.sheet + a.cell).localeCompare(b.sheet + b.cell));
        },
        // Writes a 2D array of values (a string starting with = is a
        // formula) at the range's top-left cell, in the tab of the URL's gid,
        // typed cell by cell; an empty value leaves its cell as it is.
        // Private sheet: at once; otherwise a draft that write(draftId, { confirm: true }) applies.
        // { status: "written", range, verified }.
        write(sheet, range, values, options) {
          return writeCells("write", sheet, range, values, options);
        },
        // Appends rows after the last non-empty row: { status, range, verified }.
        async append(sheet, rows, options) {
          if (typeof sheet === "string" && /^draft-\d+-[0-9a-f]+$/.test(sheet)) return writeCells("append", sheet, rows, undefined, options);
          const { rows: current } = await api.read(sheet, options || {});
          let last = current.length;
          while (last > 0 && current[last - 1].every((v) => v === "")) last--;
          return writeCells("append", sheet, `A${last + 1}`, rows, options);
        },
        // Clears the values in a range: { status: "cleared", range, verified }.
        clear(sheet, range, options) {
          if (typeof sheet === "string" && /^draft-\d+-[0-9a-f]+$/.test(sheet)) return ed.edit("googleSheets", "clear", "googleSheets.clear", null, sheet, range);
          const r = ref(sheet, "googleSheets.clear", options || {});
          S.parseA1Range(range);
          return ed.edit("googleSheets", "clear", "googleSheets.clear", r, { range }, options, () => ({
            summary: `Clear ${range} in Google Sheet ${r.id}`,
            preview: { file: sheet, range },
            run: async (page) => {
              await selectRange(page, range);
              await page.keyboard.press("Delete");
              await ed.saved(page);
              const verified = await ed.verify(async () => (await api.cells(sheet, { ...(options || {}), range })).cells.length === 0);
              return { status: "cleared", range: range.toUpperCase(), verified };
            },
          }));
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
