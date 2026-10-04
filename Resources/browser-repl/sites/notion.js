// sites.notion: Notion's web API (/api/v3, the endpoints its web app uses,
// shapes as documented by the open-source notion-client/notion-py projects)
// called same-origin from a background www.notion.so tab, so the httpOnly
// session cookie authenticates and never reaches the REPL.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const ORIGIN = "https://www.notion.so";

  async function notionCall(arg) {
    const headers = { "content-type": "application/json" };
    if (arg.userId) headers["x-notion-active-user-header"] = arg.userId;
    const out = [];
    for (const c of arg.calls) {
      const r = await fetch("/api/v3/" + c.endpoint, { method: "POST", headers, body: JSON.stringify(c.body), credentials: "include" });
      let json = null;
      try {
        json = await r.json();
      } catch (e) {}
      out.push({ status: r.status, json });
      if (!r.ok) break;
    }
    return out;
  }

  const rec = (r) => (r && r.value && r.value.value && r.value.value.id ? r.value.value : r && r.value);
  const plain = (title) => (Array.isArray(title) ? title.map((t) => t[0]).join("") : "");
  const dashed = (id) => id.replace(/-/g, "").replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, "$1-$2-$3-$4-$5");
  function pageId(input) {
    const m = /([0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:[?#]|$)/i.exec(String(input || "").trim());
    if (!m) throw new S.SiteError("invalid", `notion: expected a Notion page URL or id, got ${JSON.stringify(input)}`);
    return dashed(m[1].toLowerCase());
  }
  const uuid = () => "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => ((c === "x" ? Math.random() * 16 : (Math.random() * 4) | 8) | 0).toString(16));

  // Notion rich text -> Markdown.
  function inline(title) {
    if (!Array.isArray(title)) return "";
    return title
      .map(([text, formats]) => {
        let s = text;
        for (const f of formats || []) {
          if (f[0] === "b") s = `**${s}**`;
          else if (f[0] === "i") s = `*${s}*`;
          else if (f[0] === "s") s = `~~${s}~~`;
          else if (f[0] === "c") s = "`" + s + "`";
          else if (f[0] === "a") s = `[${s}](${f[1]})`;
          else if (f[0] === "p") s = `[page](${ORIGIN}/${String(f[1]).replace(/-/g, "")})`;
        }
        return s;
      })
      .join("");
  }

  function toMarkdown(blocks, id) {
    const lines = [];
    const render = (bid, depth) => {
      const b = blocks[bid];
      if (!b || b.alive === false) return;
      const p = b.properties || {};
      const pad = "  ".repeat(depth);
      const t = inline(p.title);
      const kids = (list, d) => (list || []).forEach((c) => render(c, d));
      switch (b.type) {
        case "page":
          if (bid === id) {
            lines.push(`# ${t}`, "");
            kids(b.content, 0);
            return;
          }
          lines.push(`${pad}[${plain(p.title) || "Untitled"}](${ORIGIN}/${bid.replace(/-/g, "")})`);
          return;
        case "header": lines.push(`## ${t}`); break;
        case "sub_header": lines.push(`### ${t}`); break;
        case "sub_sub_header": lines.push(`#### ${t}`); break;
        case "bulleted_list": case "toggle": lines.push(`${pad}- ${t}`); kids(b.content, depth + 1); return;
        case "numbered_list": lines.push(`${pad}1. ${t}`); kids(b.content, depth + 1); return;
        case "to_do": lines.push(`${pad}- [${plain(p.checked) === "Yes" ? "x" : " "}] ${t}`); kids(b.content, depth + 1); return;
        case "quote": case "callout": lines.push(`${pad}> ${t}`); break;
        case "code": lines.push("```" + plain(p.language).toLowerCase(), plain(p.title), "```"); break;
        case "divider": lines.push("---"); break;
        case "equation": lines.push(`$$${plain(p.title)}$$`); break;
        case "image": case "video": case "file": case "pdf": case "bookmark": case "embed": lines.push(`${pad}[${b.type}](${plain(p.source) || plain(p.link)})`); break;
        case "table": {
          const order = (b.format && b.format.table_block_column_order) || [];
          const rows = (b.content || []).map((r) => blocks[r]).filter(Boolean).map((r) => "| " + order.map((c) => inline((r.properties || {})[c]).replace(/\|/g, "\\|")).join(" | ") + " |");
          if (rows.length) lines.push(rows[0], "| " + order.map(() => "---").join(" | ") + " |", ...rows.slice(1));
          return;
        }
        case "column_list": case "column": case "transclusion_container": case "transclusion_reference": kids(b.content, depth); return;
        default: if (t) lines.push(`${pad}${t}`);
      }
      if (b.content && b.type !== "page") kids(b.content, depth + 1);
    };
    render(id, 0);
    return lines.join("\n").replace(/\n{3,}/g, "\n\n").trim() + "\n";
  }

  // Markdown -> Notion rich text: **bold**, *italic*, `code`, [text](url).
  function richText(s) {
    const out = [];
    const re = /\*\*([^*]+)\*\*|\*([^*]+)\*|`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)/g;
    let at = 0;
    for (let m; (m = re.exec(s)); ) {
      if (m.index > at) out.push([s.slice(at, m.index)]);
      if (m[1] !== undefined) out.push([m[1], [["b"]]]);
      else if (m[2] !== undefined) out.push([m[2], [["i"]]]);
      else if (m[3] !== undefined) out.push([m[3], [["c"]]]);
      else out.push([m[4], [["a", m[5]]]]);
      at = re.lastIndex;
    }
    if (at < s.length) out.push([s.slice(at)]);
    return out.length ? out : [[""]];
  }

  // Markdown -> [{ type, properties }] (headings, lists, to-dos, quotes, code, dividers, paragraphs).
  function blocksFromMarkdown(md) {
    const out = [];
    const lines = String(md).replace(/\r\n?/g, "\n").split("\n");
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (!line.trim()) continue;
      let m;
      if ((m = /^```(\w*)\s*$/.exec(line))) {
        const code = [];
        while (++i < lines.length && !/^```\s*$/.test(lines[i])) code.push(lines[i]);
        out.push({ type: "code", properties: { title: [[code.join("\n")]], language: [[m[1] || "Plain Text"]] } });
      } else if ((m = /^(#{1,3})\s+(.*)$/.exec(line))) out.push({ type: ["header", "sub_header", "sub_sub_header"][m[1].length - 1], properties: { title: richText(m[2]) } });
      else if ((m = /^\s*[-*]\s+\[( |x|X)\]\s+(.*)$/.exec(line))) out.push({ type: "to_do", properties: { title: richText(m[2]), checked: [[m[1] === " " ? "No" : "Yes"]] } });
      else if ((m = /^\s*[-*]\s+(.*)$/.exec(line))) out.push({ type: "bulleted_list", properties: { title: richText(m[1]) } });
      else if ((m = /^\s*\d+[.)]\s+(.*)$/.exec(line))) out.push({ type: "numbered_list", properties: { title: richText(m[1]) } });
      else if ((m = /^>\s?(.*)$/.exec(line))) out.push({ type: "quote", properties: { title: richText(m[1]) } });
      else if (/^(---+|\*\*\*+)\s*$/.test(line)) out.push({ type: "divider", properties: {} });
      else out.push({ type: "text", properties: { title: richText(line.trim()) } });
    }
    return out;
  }

  S.register(
    "notion",
    (t) => {
      // Notion's app and session live on app.notion.com; older sessions on www.notion.so.
      const API_ORIGINS = ["https://app.notion.com", ORIGIN];
      // { origin } pins one of API_ORIGINS (exactly); null when not given.
      // Calls run with the user's Notion cookies, so no other origin is accepted.
      const pinned = (o) => {
        if (!o || o.origin === undefined || o.origin === null) return null;
        if (!API_ORIGINS.includes(o.origin)) throw new S.SiteError("invalid", `notion: origin: expected one of ${API_ORIGINS.join(", ")}, got ${JSON.stringify(o.origin)}`);
        return o.origin;
      };
      const origin = (o) => pinned(o) || ORIGIN;
      let apiOrigin = null;
      async function calls(list, options = {}) {
        const fixed = pinned(options);
        let rs;
        for (const o of fixed ? [fixed] : apiOrigin ? [apiOrigin] : API_ORIGINS) {
          rs = await t.inOrigin(o, notionCall, { calls: list, userId: options.userId });
          if (rs[0] && rs[0].status !== 401) {
            if (!fixed) apiOrigin = o;
            break;
          }
        }
        for (let i = 0; i < rs.length; i++) {
          const r = rs[i];
          if (r.status === 401 || (r.json && /unauthorized|not logged in/i.test(r.json.name || r.json.message || ""))) throw new S.SiteError("not_signed_in", "notion: the cmux browser is not signed in to Notion; open https://www.notion.so with tabs.open() and ask the user to sign in");
          if (r.status < 200 || r.status >= 300) throw new S.SiteError("http", `notion ${list[i].endpoint}: HTTP ${r.status}${r.json && r.json.message ? `: ${r.json.message}` : ""}`);
        }
        return rs.map((r) => r.json);
      }
      async function spaces(options) {
        const [data] = await calls([{ endpoint: "getSpaces", body: {} }], options);
        return Object.entries(data || {}).map(([userId, v]) => {
          const user = rec((v.notion_user || {})[userId]) || {};
          return { userId, email: user.email || null, name: user.name || [user.given_name, user.family_name].filter(Boolean).join(" ") || null, spaces: Object.entries(v.space || {}).map(([id, s]) => ({ id, name: (rec(s) || {}).name || null })) };
        });
      }
      async function loadPage(id, options) {
        const blocks = {};
        let cursor = { stack: [] };
        for (let chunk = 0; chunk < 30; chunk++) {
          const [r] = await calls([{ endpoint: "loadPageChunk", body: { pageId: id, limit: 100, cursor, chunkNumber: chunk, verticalColumns: false } }], options);
          for (const [k, v] of Object.entries((r.recordMap && r.recordMap.block) || {})) if (rec(v)) blocks[k] = rec(v);
          cursor = r.cursor;
          if (!cursor || !cursor.stack || !cursor.stack.length) break;
        }
        // Children the chunks did not include.
        for (let round = 0; round < 5; round++) {
          const missing = [...new Set(Object.values(blocks).flatMap((b) => (b.type === "page" && b.id !== id ? [] : b.content || [])))].filter((c) => !blocks[c]);
          if (!missing.length) break;
          const [r] = await calls([{ endpoint: "syncRecordValues", body: { requests: missing.slice(0, 200).map((c) => ({ pointer: { table: "block", id: c }, version: -1 })) } }], options);
          let added = 0;
          for (const [k, v] of Object.entries((r.recordMap && r.recordMap.block) || {})) if (rec(v)) (blocks[k] = rec(v)), added++;
          if (!added) break;
        }
        if (!blocks[id]) throw new S.SiteError("not_found", `notion.read: page ${id} was not found or this account cannot open it`);
        return blocks;
      }
      return {
        pageId,
        // [{ userId, email, name, spaces: [{ id, name }] }]
        accounts: (options = {}) => spaces(options),
        // [{ id, title, url, highlight }]. Options: spaceId (default: the first), limit, userId.
        async search(query, options = {}) {
          let spaceId = options.spaceId;
          if (!spaceId) {
            const acc = await spaces(options);
            const first = acc.find((a) => !options.userId || a.userId === options.userId);
            spaceId = first && first.spaces[0] && first.spaces[0].id;
            if (!spaceId) throw new S.SiteError("not_found", "notion.search: no workspace found for this account");
          }
          const [r] = await calls([{ endpoint: "search", body: { type: "BlocksInSpace", query: String(query), spaceId, limit: options.limit || 20, filters: { isDeletedOnly: false, excludeTemplates: true, navigableBlockContentOnly: true, requireEditPermissions: false, ancestors: [], createdBy: [], editedBy: [], lastEditedTime: {}, createdTime: {}, inTeams: [] }, sort: { field: "relevance" }, source: "quick_find" } }], options);
          const blocks = (r.recordMap && r.recordMap.block) || {};
          return (r.results || []).map((x) => {
            const b = rec(blocks[x.id]) || {};
            return { id: x.id, title: plain((b.properties || {}).title) || (x.highlight && x.highlight.title) || null, url: `${origin(options)}/${x.id.replace(/-/g, "")}`, highlight: (x.highlight && x.highlight.text) || null };
          });
        },
        // { id, title, url, markdown }
        async read(page, options = {}) {
          const id = pageId(page);
          const blocks = await loadPage(id, options);
          return { id, title: plain((blocks[id].properties || {}).title), url: `${origin(options)}/${id.replace(/-/g, "")}`, markdown: toMarkdown(blocks, id) };
        },
        // Draft appending Markdown to the end of a page (headings, lists,
        // to-dos, quotes, code, dividers, paragraphs). append(draftId, { confirm: true }) writes it.
        append(page, markdown, options) {
          const isDraft = typeof page === "string" && /^draft-\d+-[0-9a-f]+$/.test(page);
          return t.write("notion", "append", isDraft ? page : { page, markdown, ...(options || {}) }, isDraft ? markdown : undefined, async (input) => {
            const id = pageId(input.page);
            pinned(input);
            if (typeof input.markdown !== "string" || !input.markdown.trim()) throw new S.SiteError("invalid", "notion.append: markdown: expected non-empty text");
            const newBlocks = blocksFromMarkdown(input.markdown);
            // The draft names the Notion user it writes as: { userId } when
            // given, else the one user the session holds (several: pass
            // { userId }, see notion.accounts()).
            const users = await spaces({ ...input, userId: undefined });
            const user = input.userId ? users.find((u) => u.userId === input.userId) : users.length === 1 ? users[0] : null;
            if (!user) {
              if (!users.length || input.userId) throw new S.SiteError("not_signed_in", `notion.append: ${input.userId ? `the Notion user ${input.userId} is not` : "no Notion user is"} signed in to the cmux browser; open https://www.notion.so with tabs.open() and ask the user to sign in`);
              throw new S.SiteError("invalid", `notion.append: several Notion users are signed in (${users.map((u) => `${u.email || u.name} = ${u.userId}`).join(", ")}); pass { userId } to choose the one that writes`);
            }
            const account = { userId: user.userId, email: user.email };
            const as = { ...input, userId: account.userId };
            return {
              category: "[9] edit shared content",
              summary: `Append ${newBlocks.length} block(s) to Notion page ${id} as ${account.email || account.userId}`,
              preview: { page: id, account, blocks: newBlocks.length, markdown: input.markdown },
              run: async () => {
                // Who the session holds now (no user named, so another user
                // answers as themself), then the page and the write, both
                // naming the drafted user in x-notion-active-user-header:
                // Notion runs them as that user or refuses them, also when
                // the session switches users between these calls.
                const [nowSpaces] = await calls([{ endpoint: "getSpaces", body: {} }], { ...input, userId: undefined });
                const holder = rec(((nowSpaces && nowSpaces[account.userId] && nowSpaces[account.userId].notion_user) || {})[account.userId]);
                if (!holder || (holder.email || null) !== account.email) {
                  const others = Object.entries(nowSpaces || {}).map(([uid, v]) => (rec((v.notion_user || {})[uid]) || {}).email || uid);
                  throw new S.SiteError("account_changed", `notion.append: the signed-in Notion user is now ${others.join(", ") || "nobody"}, not ${account.email || account.userId} as drafted; nothing was written. Make a new draft and show it to the user again`);
                }
                const [r] = await calls([{ endpoint: "syncRecordValues", body: { requests: [{ pointer: { table: "block", id }, version: -1 }] } }], as);
                const parent = rec(((r.recordMap || {}).block || {})[id]);
                if (!parent) throw new S.SiteError("not_found", `notion.append: page ${id} was not found`);
                const spaceId = parent.space_id;
                const now = t.now();
                const ops = [];
                let after = (parent.content || []).slice(-1)[0];
                const ids = [];
                for (const b of newBlocks) {
                  const bid = uuid();
                  ids.push(bid);
                  ops.push({ pointer: { table: "block", id: bid, spaceId }, path: [], command: "set", args: { type: b.type, id: bid, version: 1, alive: true, parent_id: id, parent_table: "block", space_id: spaceId, properties: b.properties, created_time: now, last_edited_time: now } });
                  ops.push({ pointer: { table: "block", id, spaceId }, path: ["content"], command: "listAfter", args: after ? { after, id: bid } : { id: bid } });
                  after = bid;
                }
                await calls([{ endpoint: "saveTransactions", body: { requestId: uuid(), transactions: [{ id: uuid(), spaceId, debug: { userAction: "cmux.sites.notion.append" }, operations: ops }] } }], as);
                return { status: "appended", page: id, blockIds: ids };
              },
            };
          });
        },
      };
    },
    { summary: "Notion accounts, search, pages as Markdown; confirmed-draft Markdown append" },
  );
  S.shared.notion = { toMarkdown, blocksFromMarkdown, richText, pageId };
})(typeof globalThis !== "undefined" ? globalThis : this);
