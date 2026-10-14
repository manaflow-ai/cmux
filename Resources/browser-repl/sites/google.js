// Shared Google helpers for the site tools: Docs/Sheets/Slides/Drive URL
// parsing and Google's own export endpoints, fetched in the signed-in session.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL, URLSearchParams } = root.CmuxBrowserRepl.core;

  // Formats Google's export endpoint serves per file kind.
  const FORMATS = {
    document: ["md", "pdf", "docx", "txt", "html", "odt", "rtf", "epub"],
    spreadsheets: ["xlsx", "csv", "tsv", "pdf", "ods", "html"],
    presentation: ["pptx", "pdf", "txt", "odp"],
  };
  const KIND_NAMES = { document: "Google Docs document", spreadsheets: "Google Sheets spreadsheet", presentation: "Google Slides presentation", file: "Drive file" };

  // A Docs/Sheets/Slides/Drive URL or { id, kind, uid } -> { kind, id, uid, gid, tab }.
  function parse(input, name, want) {
    let ref;
    if (input && typeof input === "object") ref = { kind: input.kind || want || null, id: input.id || input.docId, uid: input.uid, gid: input.gid, tab: input.tab };
    else {
      const s = String(input || "");
      if (/^[\w-]{20,}$/.test(s)) ref = { kind: want || null, id: s };
      else {
        let u;
        try {
          u = new URL(s);
        } catch {
          throw new S.SiteError("invalid", `${name}: expected a Google Docs, Sheets, Slides or Drive URL or file id, got ${JSON.stringify(input)}`);
        }
        const parts = u.pathname.split("/").filter(Boolean);
        const uidAt = parts.indexOf("u");
        const uid = uidAt >= 0 ? Number(parts[uidAt + 1]) : u.searchParams.has("authuser") ? Number(u.searchParams.get("authuser")) : undefined;
        const dAt = parts.indexOf("d");
        if (u.hostname === "docs.google.com" && FORMATS[parts[0]] && dAt > 0) {
          const hashGid = /(?:^|[#&])gid=(\d+)/.exec(u.hash.slice(1));
          ref = { kind: parts[0], id: parts[dAt + 1], uid, gid: u.searchParams.get("gid") || (hashGid && hashGid[1]) || undefined, tab: u.searchParams.get("tab") || undefined };
        } else if (u.hostname === "drive.google.com" && dAt > 0 && parts[dAt - 1] === "file") ref = { kind: "file", id: parts[dAt + 1], uid };
        else if (u.hostname === "drive.google.com" && u.searchParams.get("id")) ref = { kind: "file", id: u.searchParams.get("id"), uid };
        else throw new S.SiteError("invalid", `${name}: expected a Google Docs, Sheets, Slides or Drive URL, got ${s}`);
      }
    }
    if (!ref.id || !/^[\w-]+$/.test(ref.id)) throw new S.SiteError("invalid", `${name}: no file id in ${JSON.stringify(input)}`);
    if (want && ref.kind && ref.kind !== want && ref.kind !== "file") throw new S.SiteError("invalid", `${name}: expected a ${KIND_NAMES[want]}, got a ${KIND_NAMES[ref.kind]}`);
    if (want && !ref.kind) ref.kind = want;
    if (ref.uid !== undefined && !(Number.isInteger(ref.uid) && ref.uid >= 0)) throw new S.SiteError("invalid", `${name}: uid: expected a non-negative integer, got ${JSON.stringify(ref.uid)}`);
    return ref;
  }

  function exportURL(ref, format, name) {
    const allowed = FORMATS[ref.kind];
    if (!allowed) throw new S.SiteError("invalid", `${name}: ${ref.id} is a Drive file, not a Google Docs, Sheets or Slides file; use sites.googleDrive.download()`);
    if (!allowed.includes(format)) throw new S.SiteError("invalid", `${name}: format: expected one of ${allowed.join(", ")} for a ${KIND_NAMES[ref.kind]}, got ${JSON.stringify(format)}`);
    const q = new URLSearchParams({ format });
    if (ref.kind === "spreadsheets" && ref.gid !== undefined && ref.gid !== null) q.set("gid", String(ref.gid));
    if (ref.tab) q.set("tab", ref.tab);
    if (ref.uid !== undefined) q.set("authuser", String(ref.uid));
    return `https://docs.google.com/${ref.kind}/d/${ref.id}/export?${q}`;
  }

  // "attachment; filename="A.md"; filename*=UTF-8''A%20b.md" -> "A b.md"
  function dispositionName(value) {
    if (!value) return null;
    const star = /filename\*=(?:UTF-8'')?([^;]+)/i.exec(value);
    if (star) {
      try {
        return decodeURIComponent(star[1].trim().replace(/^"|"$/g, ""));
      } catch {}
    }
    const plain = /filename="?([^";]+)"?/i.exec(value);
    return plain ? plain[1] : null;
  }

  // Fetches a Google URL in the signed-in session; fails clearly when Google
  // sends the sign-in page or an HTML error instead of the file.
  async function fetchFile(t, name, url, { expectHTML = false } = {}) {
    // Google limits export requests in quick succession (429); wait and retry.
    let r = await t.fetch(url);
    for (const wait of [2000, 4000, 8000]) {
      if (r.status !== 429) break;
      await t.sleep(wait);
      r = await t.fetch(url);
    }
    if (r.status === 429) throw new S.SiteError("rate_limited", `${name}: Google limits export requests (HTTP 429); retry in a few seconds`);
    if (/^https:\/\/accounts\.google\.com\//.test(r.url) || r.status === 401) throw new S.SiteError("not_signed_in", `${name}: Google asked to sign in (no signed-in account in the cmux browser can open this file). Open ${url.split("?")[0]} with tabs.open() and ask the user to sign in.`);
    if (r.status === 403 || r.status === 404) throw new S.SiteError(r.status === 404 ? "not_found" : "forbidden", `${name}: Google returned HTTP ${r.status}; the file does not exist or this account (uid ${new URL(url).searchParams.get("authuser") || 0}) has no access. Try another { uid } (sites.googleAccounts.list()).`);
    if (!r.ok) throw new S.SiteError("http", `${name}: Google returned HTTP ${r.status} for ${url}`);
    const type = (r.headers.get("content-type") || "").toLowerCase();
    if (!expectHTML && type.startsWith("text/html")) throw new S.SiteError("unexpected", `${name}: Google returned a web page instead of the file (${r.url.split("?")[0]}); the file may be too large to export or need a confirmation in the browser`);
    const title = dispositionName(r.headers.get("content-disposition"));
    return { response: r, title: title ? title.replace(/\.[a-z0-9]+$/i, "") : null, contentType: type || null };
  }

  // Exports to a file; returns { path, title, format }.
  async function exportTo(t, name, ref, format, options = {}) {
    const url = exportURL(ref, format, name);
    const { response, title } = await fetchFile(t, name, url);
    const file = t.outputPath(options, "." + format, title || `${ref.kind}-${ref.id}`);
    t.fs.writeFileSync(file, t.Buffer.from(await response.arrayBuffer()));
    return { path: file, title, format };
  }

  async function exportText(t, name, ref, format) {
    const url = exportURL(ref, format, name);
    const { response, title } = await fetchFile(t, name, url, { expectHTML: format === "html" });
    let text = await response.text();
    // Google's Markdown export embeds each image as a data: reference
    // definition (most of a document with images); keep the references.
    if (format === "md") text = text.replace(/^[ \t]*\[[^\]]+\]:[ \t]*<data:[^>]*>[ \t]*\n?/gm, "").replace(/\n{3,}/g, "\n\n").replace(/\n+$/, "\n");
    return { title, text };
  }

  S.shared.google = { FORMATS, parse, exportURL, dispositionName, fetchFile, exportTo, exportText };
})(typeof globalThis !== "undefined" ? globalThis : this);
