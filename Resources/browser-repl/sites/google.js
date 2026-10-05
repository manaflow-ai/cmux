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

  // The Google accounts signed in to the browser, [{ uid, name, email,
  // signedOut }], from Google's ListAccounts endpoint (the one Chromium's
  // account reconcilor uses; shape parsed as in Chromium's
  // google_apis/gaia/gaia_auth_util.cc: [2] name, [3] email, [14] signed
  // out). uid is the /u/{uid}/ and authuser index. Cookie-only, no tab.
  async function listAccounts(t, name) {
    const r = await t.fetch("https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "" });
    if (!r.ok) throw new S.SiteError("http", `${name}: HTTP ${r.status}`);
    let data;
    try {
      data = JSON.parse((await r.text()).replace(/^\)\]\}'\s*/, ""));
    } catch {
      throw new S.SiteError("unexpected", `${name}: Google's answer was not the ListAccounts JSON`);
    }
    const rows = Array.isArray(data) && Array.isArray(data[1]) ? data[1] : [];
    return rows
      .filter((a) => Array.isArray(a) && typeof a[3] === "string")
      .map((a, i) => ({ uid: i, id: typeof a[10] === "string" && a[10] ? a[10] : null, name: typeof a[2] === "string" ? a[2] : "", email: a[3], signedOut: a[14] === 1 || a[14] === true }));
  }

  // The signed-in account at /u/{uid}/, { uid, email, id } (id: Google's
  // stable account id, ListAccounts [10]). A draft pins it: the index is
  // positional, so signing an account in or out (another session can)
  // moves another account to that index.
  async function accountAt(t, name, uid) {
    const account = (await listAccounts(t, name)).find((a) => a.uid === uid);
    if (!account || account.signedOut) throw new S.SiteError("not_signed_in", `${name}: no signed-in Google account at /u/${uid}/; see sites.googleAccounts.list()`);
    if (!account.id) throw new S.SiteError("account_unverified", `${name}: Google did not give the account id of /u/${uid}/; nothing was drafted`);
    return { uid, email: account.email, id: account.id };
  }

  // Runs in a Gmail, Calendar or editor page: the emails of the Google
  // account the page names in its own chrome, null when it names none
  // yet. Only the app's title suffix ("Inbox - ada@example.com - Gmail":
  // the last " - <email> - <app>", so a subject that holds an address does
  // not count) and Google Account buttons outside the page's content (the
  // main area, dialogs, editable text and message bodies, which senders
  // and collaborators write) count.
  function pageAccountEmails() {
    const out = new Set();
    const email = /[^\s()<>"',;:]+@[^\s()<>"',;:]+\.[A-Za-z]{2,}/g;
    const title = / - ([^\s]+@[^\s]+\.[A-Za-z]{2,}) - [^-]*$/.exec(document.title || "");
    if (title) out.add(title[1].toLowerCase());
    for (const el of document.querySelectorAll('[aria-label^="Google Account"]')) {
      if (el.closest('[role="main"], [role="dialog"], [contenteditable], .a3s, .kix-appview-editor')) continue;
      for (const m of (el.getAttribute("aria-label") || "").matchAll(email)) out.add(m[0].toLowerCase());
    }
    return out.size ? [...out] : null;
  }

  // The one Google account the loaded page names (an editor's header, a
  // Gmail title), which a draft shows: account_unverified when the page
  // names none, or more than one.
  async function pageAccount(t, name, page) {
    const found = await t.waitIn(page, pageAccountEmails, undefined, { timeout: 10000, what: "the page to name its Google account" }).catch(() => null);
    if (!found || found.length !== 1) throw new S.SiteError("account_unverified", `${name}: could not tell which Google account ${page.url().split("?")[0]} is signed in as${found ? ` (it names ${found.join(", ")})` : ""}; nothing was changed`);
    return found[0];
  }

  // For a commit's observe(), right before the write: the account `page`
  // acts as, { account: uid, accountEmail, accountId }. uid is the page's
  // own /u/N/ (or authuser) index, or `uid` for a page whose URL has none
  // (an editor opened without one acts as /u/0/); the email and id come
  // from Google's ListAccounts (server state) for that index, read last,
  // and count only when the page's own chrome names that same email and no
  // other. A field it cannot establish is left out (unverified); a page
  // that names another account than Google's list makes the email a
  // mismatch.
  async function observeAccount(t, name, page, uid) {
    let at = uid;
    try {
      const u = new URL(page.url());
      const m = /\/u\/(\d+)(?:\/|$)/.exec(u.pathname);
      if (m) at = Number(m[1]);
      else if (/^\d+$/.test(u.searchParams.get("authuser") || "")) at = Number(u.searchParams.get("authuser"));
    } catch (e) {}
    if (at === undefined || at === null) at = 0;
    const named = await t.waitIn(page, pageAccountEmails, undefined, { timeout: 10000, what: "the page to name its Google account" }).catch(() => null);
    const row = (await listAccounts(t, name)).find((a) => a.uid === at);
    const out = { account: at };
    if (!row || row.signedOut || !named) return out;
    const other = named.find((e) => e !== row.email.toLowerCase());
    out.accountEmail = other ? `${row.email} (the page names ${other})` : row.email;
    if (row.id) out.accountId = row.id;
    return out;
  }

  S.shared.google = { FORMATS, parse, exportURL, dispositionName, fetchFile, exportTo, exportText, listAccounts, accountAt, pageAccount, observeAccount, pageAccountEmails };
})(typeof globalThis !== "undefined" ? globalThis : this);
