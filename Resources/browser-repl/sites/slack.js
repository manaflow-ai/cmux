// sites.slack: Slack Web API methods (docs.slack.dev) called from a
// background tab on app.slack.com, the way Slack's own web client calls
// them: the workspace token stays in that page's localStorage and the
// request carries the session cookie. Nothing returns the token.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const APP = "https://app.slack.com";

  // Runs in app.slack.com. arg: { list } or { team, method, params,
  // expect }. With expect { teamId, userId }, auth.test runs first with the
  // same token and the method runs only when that token is that member of
  // that workspace: a token names one member, so the method acts as them.
  async function slackCall(arg) {
    let config = null;
    try {
      config = JSON.parse(localStorage.getItem("localConfig_v2") || "null");
    } catch (e) {}
    const teams = config && config.teams ? Object.values(config.teams) : [];
    if (!teams.length) return { error: "not_signed_in" };
    if (arg.list) return { teams: teams.map((t) => ({ teamId: t.id, name: t.name, domain: t.domain, url: t.url, userId: t.user_id || null, enterpriseId: t.enterprise_id || null, lastActive: config.lastActiveTeamId === t.id })) };
    const team = arg.team ? teams.find((t) => t.id === arg.team || t.domain === arg.team || t.name === arg.team) : teams.find((t) => t.id === config.lastActiveTeamId) || teams[0];
    if (!team) return { error: "unknown_team", teams: teams.map((t) => t.id + " " + t.name) };
    const token = team.token;
    if (arg.expect) {
      const who = new FormData();
      who.append("token", token);
      const a = await fetch(location.origin + "/api/auth.test", { method: "POST", body: who, credentials: "include" });
      let auth = null;
      try {
        auth = await a.json();
      } catch (e) {}
      if (!auth || !auth.ok) return { status: a.status, teamId: team.id, json: auth };
      if (auth.team_id !== arg.expect.teamId || auth.user_id !== arg.expect.userId) return { error: "account_changed", now: { teamId: auth.team_id, userId: auth.user_id, user: auth.user || null } };
    }
    const body = new FormData();
    body.append("token", token);
    for (const [k, v] of Object.entries(arg.params || {})) if (v !== undefined && v !== null) body.append(k, typeof v === "object" ? JSON.stringify(v) : String(v));
    // Same-origin, as the web client calls it; the token selects the
    // workspace (workspace hosts refuse cross-origin calls).
    const r = await fetch(location.origin + "/api/" + arg.method, { method: "POST", body, credentials: "include" });
    let json = null;
    try {
      json = await r.json();
    } catch (e) {}
    return { status: r.status, teamId: team.id, json };
  }

  // Methods that only read. Anything else goes through a confirmed draft.
  const READ = /^(auth\.test|team\.info|bots\.info|emoji\.list|dnd\.info|users\.(info|list|lookupByEmail|conversations|getPresence|profile\.get)|conversations\.(list|history|replies|info|members)|search\.(messages|files|all)|files\.(info|list)|pins\.list|reactions\.(get|list)|stars\.list|bookmarks\.list|usergroups\.(list|users\.list)|reminders\.(info|list))$/;

  S.register(
    "slack",
    (t) => {
      // body(call) runs with one app.slack.com tab; call(team, method, params) -> JSON.
      // A fresh profile has no workspace config until Slack's web client
      // boots once; load it in the background tab when it is missing.
      const hasConfig = () => {
        try {
          const c = JSON.parse(localStorage.getItem("localConfig_v2") || "null");
          return !!(c && c.teams && Object.keys(c.teams).length);
        } catch (e) {
          return false;
        }
      };
      const slackPage = (body) =>
        t.withTab(APP + "/robots.txt", async (page) => {
          if (!(await page.evaluate(hasConfig))) {
            await page.goto(APP + "/client", { waitUntil: "load", timeout: 45000 });
            await t.waitIn(page, hasConfig, undefined, { timeout: 30000, what: "Slack's web client to load the workspaces", name: "slack" }).catch(() => {});
          }
          return body((fn, arg) => page.evaluate(fn, arg));
        });
      const withSlack = (body) =>
        slackPage((run) =>
          body(async (team, method, params, expect) => {
            const r = await run(slackCall, { team, method, params, expect });
            if (r.error === "account_changed") throw new S.SiteError("account_changed", `slack ${method}: the workspace's signed-in member is now ${r.now.user || r.now.userId} (${r.now.userId}) in ${r.now.teamId}, not ${expect.userId} in ${expect.teamId} as drafted; nothing was sent. Make a new draft and show it to the user again`);
            if (r.error === "not_signed_in") throw new S.SiteError("not_signed_in", "slack: the cmux browser is not signed in to Slack; open https://app.slack.com with tabs.open() and ask the user to sign in");
            if (r.error === "unknown_team") throw new S.SiteError("not_found", `slack: no signed-in workspace ${JSON.stringify(team)}; workspaces: ${r.teams.join(", ")}`);
            if (!r.json) throw new S.SiteError("http", `slack ${method}: HTTP ${r.status}`);
            if (!r.json.ok) throw new S.SiteError(r.json.error === "invalid_auth" || r.json.error === "not_authed" ? "not_signed_in" : "slack_error", `slack ${method}: ${r.json.error}${r.json.needed ? ` (needs ${r.json.needed})` : ""}`);
            return r.json;
          }),
        );
      const msg = (m) => ({ ts: m.ts, user: m.user || m.bot_id || null, text: m.text, ...(m.thread_ts && m.thread_ts !== m.ts ? { threadTs: m.thread_ts } : {}), ...(m.reply_count ? { replyCount: m.reply_count } : {}), ...(m.files ? { files: m.files.map((f) => f.name) } : {}), ...(m.subtype ? { subtype: m.subtype } : {}) });
      async function channelId(call, team, channel) {
        if (/^[CDG][A-Z0-9]{6,}$/.test(channel)) return channel;
        const name = String(channel).replace(/^#/, "");
        let cursor;
        do {
          const r = await call(team, "users.conversations", { types: "public_channel,private_channel", exclude_archived: true, limit: 1000, cursor });
          const found = r.channels.find((c) => c.name === name);
          if (found) return found.id;
          cursor = r.response_metadata && r.response_metadata.next_cursor;
        } while (cursor);
        throw new S.SiteError("not_found", `slack: no channel #${name} among the user's channels`);
      }
      return {
        // [{ teamId, name, domain, url, userId, enterpriseId, lastActive }]
        async workspaces() {
          const r = await slackPage((run) => run(slackCall, { list: true }));
          if (r.error) throw new S.SiteError("not_signed_in", "slack.workspaces: the cmux browser is not signed in to Slack; open https://app.slack.com and ask the user to sign in");
          return r.teams;
        },
        // Channels the user is in: { channels: [{ id, name, isPrivate, isIm, topic, members }], nextCursor }.
        async channels(team, options = {}) {
          const r = await withSlack((call) => call(team, "users.conversations", { types: options.types || "public_channel,private_channel", exclude_archived: options.includeArchived ? false : true, limit: options.limit || 200, cursor: options.cursor }));
          return { channels: r.channels.map((c) => ({ id: c.id, name: c.name || null, isPrivate: !!c.is_private, isIm: !!c.is_im, topic: (c.topic && c.topic.value) || "", members: c.num_members })), nextCursor: (r.response_metadata && r.response_metadata.next_cursor) || undefined };
        },
        // { channel, messages: [{ ts, user, text, threadTs, replyCount, files }], nextCursor }, newest first.
        async history(team, channel, options = {}) {
          const [id, r] = await withSlack(async (call) => {
            const cid = await channelId(call, team, channel);
            return [cid, await call(team, "conversations.history", { channel: cid, limit: options.limit || 50, oldest: options.oldest, latest: options.latest, cursor: options.cursor })];
          });
          return { channel: id, messages: r.messages.map(msg), nextCursor: (r.response_metadata && r.response_metadata.next_cursor) || undefined };
        },
        async replies(team, channel, ts, options = {}) {
          const [id, r] = await withSlack(async (call) => {
            const cid = await channelId(call, team, channel);
            return [cid, await call(team, "conversations.replies", { channel: cid, ts, limit: options.limit || 100, cursor: options.cursor })];
          });
          return { channel: id, messages: r.messages.map(msg), nextCursor: (r.response_metadata && r.response_metadata.next_cursor) || undefined };
        },
        // { total, matches: [{ channel, user, username, ts, text, permalink }] }
        async search(team, query, options = {}) {
          const r = await withSlack((call) => call(team, "search.messages", { query, count: options.count || 20, page: options.page || 1, sort: options.sort || "score" }));
          const m = r.messages || {};
          return { total: m.total || 0, matches: (m.matches || []).map((x) => ({ channel: x.channel && (x.channel.name || x.channel.id), user: x.user, username: x.username, ts: x.ts, text: x.text, permalink: x.permalink })) };
        },
        async user(team, id) {
          const r = await withSlack((call) => call(team, "users.info", { user: id }));
          const u = r.user;
          return { id: u.id, name: u.name, realName: u.real_name, displayName: u.profile && u.profile.display_name, title: u.profile && u.profile.title, tz: u.tz, isBot: !!u.is_bot };
        },
        // Any read-only Web API method (list, history, replies, info, search, ...), raw JSON.
        async call(team, method, params = {}) {
          if (!READ.test(method)) throw new S.SiteError("write_requires_draft", `slack.call: ${method} is not a read-only method; post with slack.post() (a confirmed draft)`);
          return withSlack((call) => call(team, method, params));
        },
        // Draft a message: { team, channel, text, threadTs }. post(draftId, { confirm: true }) posts it.
        // The draft resolves the workspace (team omitted: Slack's last-active
        // one) and the channel (a #name) to their ids now; the preview names
        // both, and the confirmed draft posts only to those ids, so a
        // workspace switch or a channel name reused after the preview cannot
        // redirect it.
        post(input, options) {
          return t.write("slack", "post", input, options, async (m) => {
            if (!m || typeof m !== "object" || !m.channel || typeof m.text !== "string" || !m.text.trim()) throw new S.SiteError("invalid", "slack.post: expected { team, channel, text, threadTs? } with non-empty text");
            const text = m.text;
            const threadTs = m.threadTs ? String(m.threadTs) : null;
            const { team, user, channel } = await withSlack(async (call) => {
              const auth = await call(m.team, "auth.test", {});
              const teamId = auth.team_id;
              let id;
              let name;
              if (/^[CDG][A-Z0-9]{6,}$/.test(m.channel)) {
                const info = await call(teamId, "conversations.info", { channel: m.channel });
                id = info.channel.id;
                name = info.channel.name || null;
              } else {
                id = await channelId(call, teamId, m.channel);
                name = String(m.channel).replace(/^#/, "");
              }
              return { team: { id: teamId, name: auth.team || null }, user: { id: auth.user_id, name: auth.user || null }, channel: { id, name } };
            });
            const where = `${channel.name ? `#${channel.name} ` : ""}(${channel.id})`;
            return {
              category: "[9] representational communication",
              summary: `Post to ${where}${threadTs ? ` (thread ${threadTs})` : ""} in workspace ${team.name || team.id} (${team.id}) as ${user.name || user.id} (${user.id})`,
              preview: { team, user, channel, threadTs, text },
              run: async () => {
                // The token of the drafted workspace only (never the
                // last-active one), checked in the same page call to be the
                // drafted member's before chat.postMessage sends with it.
                const r = await withSlack((call) => call(team.id, "chat.postMessage", { channel: channel.id, text, thread_ts: threadTs || undefined }, { teamId: team.id, userId: user.id }));
                return { status: "posted", channel: r.channel, ts: r.ts };
              },
            };
          });
        },
      };
    },
    { summary: "Slack workspaces, channels, history, replies, search, users; confirmed-draft posts" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
