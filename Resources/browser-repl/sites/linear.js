// sites.linear: Linear's GraphQL API (schema documented at
// developers.linear.app) called from a background linear.app tab with the
// web session's cookies, the way the Linear web app calls it.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const APP = "https://linear.app";
  const API = "https://client-api.linear.app/graphql";

  async function graphql(arg) {
    const r = await fetch(arg.api, { method: "POST", headers: { "content-type": "application/json" }, credentials: "include", body: JSON.stringify({ query: arg.query, variables: arg.variables || {} }) });
    let json = null;
    try {
      json = await r.json();
    } catch (e) {}
    return { status: r.status, json };
  }

  const ISSUE_FIELDS = "id identifier title url priorityLabel createdAt updatedAt state { name type } assignee { name email } team { key name } labels { nodes { name } }";

  S.register(
    "linear",
    (t) => {
      async function q(query, variables) {
        const r = await t.inOrigin(APP, graphql, { api: API, query, variables });
        const errors = (r.json && r.json.errors) || [];
        if (r.status === 401 || errors.some((e) => /auth/i.test((e.extensions && e.extensions.code) || e.message || ""))) throw new S.SiteError("not_signed_in", "linear: the cmux browser is not signed in to Linear; open https://linear.app with tabs.open() and ask the user to sign in");
        if (errors.length) throw new S.SiteError("graphql", `linear: ${errors.map((e) => e.message).join("; ")}`);
        if (!r.json || !r.json.data) throw new S.SiteError("http", `linear: HTTP ${r.status}`);
        return r.json.data;
      }
      const key = (s) => {
        const m = /([A-Z][A-Z0-9]*-\d+)/.exec(String(s || ""));
        if (!m) throw new S.SiteError("invalid", `linear: expected an issue key such as "ENG-123" or an issue URL, got ${JSON.stringify(s)}`);
        return m[1];
      };
      const flat = (i) => ({ ...i, labels: i.labels ? i.labels.nodes.map((l) => l.name) : [] });
      return {
        // { id, name, email, organization }
        async viewer() {
          const d = await q("query { viewer { id name email organization { name urlKey } } }");
          return { id: d.viewer.id, name: d.viewer.name, email: d.viewer.email, organization: d.viewer.organization && d.viewer.organization.name };
        },
        // One issue with its description and comments.
        async issue(input) {
          const d = await q(`query($id: String!) { issue(id: $id) { ${ISSUE_FIELDS} description comments(first: 100) { nodes { body createdAt user { name } } } } }`, { id: key(input) });
          if (!d.issue) throw new S.SiteError("not_found", `linear.issue: ${key(input)} not found`);
          const i = d.issue;
          return { ...flat(i), comments: i.comments.nodes.map((c) => ({ author: c.user && c.user.name, createdAt: c.createdAt, body: c.body })) };
        },
        // Full-text issue search: [{ identifier, title, state, assignee, url, ... }].
        async search(term, options = {}) {
          const d = await q(`query($term: String!, $first: Int) { searchIssues(term: $term, first: $first) { nodes { ${ISSUE_FIELDS} } } }`, { term: String(term), first: options.limit || 25 });
          return d.searchIssues.nodes.map(flat);
        },
        // Issues assigned to the signed-in user, most recently updated first.
        async assigned(options = {}) {
          const d = await q(`query($first: Int) { viewer { assignedIssues(first: $first, orderBy: updatedAt) { nodes { ${ISSUE_FIELDS} } } } }`, { first: options.limit || 25 });
          return d.viewer.assignedIssues.nodes.map(flat);
        },
        // Any read-only GraphQL query; mutations go through the Linear UI.
        async query(text, variables) {
          if (/^\s*mutation\b/i.test(String(text))) throw new S.SiteError("write_requires_draft", "linear.query: mutations are not run by site tools; make the change in the Linear page");
          return q(String(text), variables);
        },
      };
    },
    { summary: "Linear viewer, issues with comments, search, assigned issues, read-only GraphQL" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
