// sites.jira: Jira Cloud's REST API v3 (developer.atlassian.com), called
// same-origin from a background tab on the user's Atlassian site so the
// session cookie authenticates.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL } = root.CmuxBrowserRepl.core;

  async function rest(arg) {
    const out = [];
    for (const path of arg.paths) {
      const r = await fetch(path, { headers: { accept: "application/json" }, credentials: "include" });
      let json = null;
      try {
        json = await r.json();
      } catch (e) {}
      out.push({ status: r.status, json });
    }
    return out;
  }

  // Atlassian Document Format -> Markdown (paragraphs, headings, lists, code, links, mentions).
  function adf(node, depth = 0) {
    if (!node) return "";
    if (typeof node === "string") return node;
    const kids = (sep = "") => (node.content || []).map((c) => adf(c, depth)).join(sep);
    switch (node.type) {
      case "doc": return (node.content || []).map((c) => adf(c, depth)).join("\n\n");
      case "paragraph": return kids();
      case "heading": return "#".repeat((node.attrs && node.attrs.level) || 1) + " " + kids();
      case "text": {
        let s = node.text || "";
        for (const m of node.marks || []) {
          if (m.type === "strong") s = `**${s}**`;
          else if (m.type === "em") s = `*${s}*`;
          else if (m.type === "code") s = "`" + s + "`";
          else if (m.type === "link") s = `[${s}](${m.attrs && m.attrs.href})`;
        }
        return s;
      }
      case "hardBreak": return "\n";
      case "bulletList": return (node.content || []).map((li) => "  ".repeat(depth) + "- " + adf(li, depth + 1).trim()).join("\n");
      case "orderedList": return (node.content || []).map((li, i) => "  ".repeat(depth) + `${i + 1}. ` + adf(li, depth + 1).trim()).join("\n");
      case "listItem": return (node.content || []).map((c) => adf(c, depth)).join("\n");
      case "codeBlock": return "```" + ((node.attrs && node.attrs.language) || "") + "\n" + kids() + "\n```";
      case "blockquote": return "> " + kids("\n> ");
      case "rule": return "---";
      case "mention": return "@" + ((node.attrs && (node.attrs.text || "").replace(/^@/, "")) || "user");
      case "inlineCard": return (node.attrs && node.attrs.url) || "";
      case "emoji": return (node.attrs && (node.attrs.text || node.attrs.shortName)) || "";
      default: return kids();
    }
  }

  S.register(
    "jira",
    (t) => {
      // "https://acme.atlassian.net/browse/KEY-1", or a key with { site: "acme" | "https://acme.atlassian.net" }.
      function target(input, options, name) {
        let site = options.site;
        let issueKey = null;
        const s = String(input || "");
        const m = /^(https:\/\/[\w-]+\.atlassian\.net)\/.*?\b([A-Z][A-Z0-9_]+-\d+)\b/.exec(s);
        if (m) (site = site || m[1]), (issueKey = m[2]);
        else if (/^[A-Z][A-Z0-9_]+-\d+$/.test(s)) issueKey = s;
        if (!site) throw new S.SiteError("invalid", `${name}: pass an issue URL or { site: "yourcompany" }`);
        if (!/^https:\/\//.test(site)) site = `https://${site}.atlassian.net`;
        const u = new URL(site);
        if (!/\.atlassian\.net$/.test(u.hostname)) throw new S.SiteError("invalid", `${name}: site must be an *.atlassian.net site, got ${site}`);
        return { origin: u.origin, key: issueKey };
      }
      const HOME = "https://home.atlassian.com";
      // Why the session's domain policy blocks home.atlassian.com, or null.
      function homeBlocked() {
        try {
          return t.host.policy("check", { url: HOME + "/" }) || null;
        } catch (e) {
          return null;
        }
      }
      // Jira Cloud sites of the signed-in Atlassian account, from
      // Atlassian's own site list (home.atlassian.com): [{ url, name, products }].
      async function listSites(name = "jira.sites") {
        const blocked = homeBlocked();
        if (blocked) throw new S.SiteError("blocked", `${name}: the account's site list is on ${HOME}, which the domain policy blocks (${blocked}); add "${HOME}" to session.allowedDomains; jira calls go only to a site on that list`);
        const r = await t.inOrigin(HOME, async () => {
          const res = await fetch("/gateway/api/available-sites", { method: "POST", credentials: "include", headers: { "content-type": "application/json" }, body: JSON.stringify({ products: ["jira-software.ondemand", "jira-core.ondemand", "jira-servicedesk.ondemand", "jira-product-discovery"] }) });
          let json = null;
          try {
            json = await res.json();
          } catch (e) {}
          return { status: res.status, json };
        });
        if (r.status === 401 || r.status === 403) throw new S.SiteError("not_signed_in", `${name}: the cmux browser is not signed in to Atlassian; open https://home.atlassian.com with tabs.open() and ask the user to sign in`);
        if (r.status !== 200 || !r.json) throw new S.SiteError("http", `${name}: HTTP ${r.status}`);
        return (r.json.sites || [])
          .map((x) => ({ url: x.url, name: x.displayName || x.name || null, products: x.products || x.availableProducts || [] }))
          .filter((x) => /^https:\/\/[\w-]+\.atlassian\.net\/?$/.test(x.url || "") && JSON.stringify(x.products).includes("jira"));
      }
      // Calls go only to an exact origin from the account's own site list
      // (any *.atlassian.net tenant can be created by anyone, and its own
      // /myself proves nothing about the account's sites). The list is
      // kept for the session and read again once when an origin is
      // missing. Without the list (the domain policy blocks
      // home.atlassian.com) every call fails closed before any request.
      let known = null;
      async function site(input, options, name) {
        const tgt = target(input, options, name);
        for (const fresh of known ? [false, true] : [true]) {
          if (fresh) known = (await listSites(name)).map((x) => new URL(x.url).origin);
          if (known.includes(tgt.origin)) return tgt;
        }
        throw new S.SiteError("invalid", `${name}: ${tgt.origin} is not a Jira site of the signed-in Atlassian account; its sites: ${known.join(", ") || "none"}`);
      }
      async function get(origin, paths, name) {
        const rs = await t.inOrigin(origin, rest, { paths });
        for (const r of rs) {
          if (r.status === 401) throw new S.SiteError("not_signed_in", `${name}: the cmux browser is not signed in to ${origin}; open it with tabs.open() and ask the user to sign in`);
          if (r.status === 404) throw new S.SiteError("not_found", `${name}: not found, or this account cannot see it`);
          if (r.status < 200 || r.status >= 300) throw new S.SiteError("http", `${name}: HTTP ${r.status}${r.json && r.json.errorMessages ? ": " + r.json.errorMessages.join("; ") : ""}`);
        }
        return rs.map((r) => r.json);
      }
      const summary = (origin, i) => {
        const f = i.fields || {};
        return { key: i.key, url: `${origin}/browse/${i.key}`, summary: f.summary, status: f.status && f.status.name, type: f.issuetype && f.issuetype.name, priority: f.priority && f.priority.name, assignee: f.assignee && f.assignee.displayName, reporter: f.reporter && f.reporter.displayName, labels: f.labels || [], created: f.created, updated: f.updated };
      };
      const FIELDS = "summary,status,issuetype,priority,assignee,reporter,labels,created,updated";
      return {
        // { key, url, summary, status, ..., description (Markdown), comments: [{ author, created, body }] }
        async issue(input, options = {}) {
          const { origin, key } = await site(input, options, "jira.issue");
          if (!key) throw new S.SiteError("invalid", "jira.issue: expected an issue key such as ABC-123 or an issue URL");
          const [i] = await get(origin, [`/rest/api/3/issue/${key}?fields=${FIELDS},description,comment`], "jira.issue");
          const f = i.fields || {};
          return { ...summary(origin, i), description: adf(f.description).trim(), comments: ((f.comment && f.comment.comments) || []).map((c) => ({ author: c.author && c.author.displayName, created: c.created, body: adf(c.body).trim() })) };
        },
        // JQL search: [{ key, url, summary, status, ... }].
        async search(jql, options = {}) {
          const { origin } = await site("", options, "jira.search");
          const q = `jql=${encodeURIComponent(jql)}&maxResults=${options.limit || 50}&fields=${FIELDS}`;
          let r;
          try {
            [r] = await get(origin, [`/rest/api/3/search/jql?${q}`], "jira.search");
          } catch (e) {
            if (e.code !== "not_found") throw e;
            [r] = await get(origin, [`/rest/api/3/search?${q}`], "jira.search");
          }
          return (r.issues || []).map((i) => summary(origin, i));
        },
        // Jira Cloud sites of the signed-in Atlassian account, from
        // Atlassian's own site list (home.atlassian.com): [{ url, name, products }].
        async sites() {
          const list = await listSites();
          known = list.map((x) => new URL(x.url).origin);
          return list;
        },
        // The signed-in user: { accountId, displayName, email }.
        async me(options = {}) {
          const { origin } = await site("", options, "jira.me");
          const [u] = await get(origin, ["/rest/api/3/myself"], "jira.me");
          return { accountId: u.accountId, displayName: u.displayName, email: u.emailAddress || null };
        },
      };
    },
    { summary: "Jira Cloud issues (description and comments as Markdown), JQL search, current user" },
  );
  S.shared.jira = { adf };
})(typeof globalThis !== "undefined" ? globalThis : this);
