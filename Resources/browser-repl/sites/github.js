// sites.github: issues, pull requests, diffs, files and issue lists from
// github.com in the signed-in session (private repositories included):
// pages read in a background tab, diffs and raw files through GitHub's own
// .diff and /raw/ URLs with the session cookie. api.github.com does not
// accept the browser session, so nothing here uses it.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const ORIGIN = "https://github.com";
  const SIGN_IN = [/github\.com\/(login|session)/];

  function readIssue() {
    const md = (__MD__);
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const first = (...sels) => sels.map((s) => document.querySelector(s)).find(Boolean);
    const title = first('[data-testid="issue-title"]', "bdi.js-issue-title", ".js-issue-title", "h1 .markdown-title", "h1");
    const state = first('[data-testid="header-state"]', ".gh-header-meta .State", "span.State");
    const labels = [...document.querySelectorAll('[data-testid="issue-labels"] a, .js-issue-labels a, .sidebar-labels a.IssueLabel')].map((a) => clean(a.textContent)).filter(Boolean);
    let bodies = [...document.querySelectorAll('[data-testid="markdown-body"], .js-comment-body, .comment-body.markdown-body')];
    bodies = bodies.filter((b) => !bodies.some((o) => o !== b && o.contains(b)));
    const posts = bodies.map((b) => {
      const box = b.closest('[data-testid="issue-viewer-issue-container"], [data-testid^="comment-viewer"], .timeline-comment, .js-comment-container, .TimelineItem') || b.parentElement;
      const author = box && box.querySelector('[data-testid="issue-body-header-author"], [data-testid="avatar-link"], a.author, .author');
      const time = box && box.querySelector("relative-time[datetime], time[datetime]");
      return { author: author ? clean(author.textContent) : null, createdAt: time ? time.getAttribute("datetime") : null, body: md(b) };
    });
    return { title: title ? clean(title.textContent) : document.title, state: state ? clean(state.textContent) : null, labels: [...new Set(labels)], body: posts[0] || null, comments: posts.slice(1) };
  }

  function readList(arg) {
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const re = new RegExp("^/" + arg.repo.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "/(issues|pull)/(\\d+)$");
    const out = [];
    const seen = new Set();
    for (const a of document.querySelectorAll("a[href]")) {
      const m = re.exec(new URL(a.href, location.href).pathname);
      const title = clean(a.textContent);
      if (!m || seen.has(m[2]) || !title || /^#?\d+$/.test(title)) continue;
      seen.add(m[2]);
      out.push({ number: Number(m[2]), kind: m[1] === "pull" ? "pull" : "issue", title, url: new URL(a.href, location.href).href });
      if (out.length >= arg.limit) break;
    }
    return out;
  }

  // "owner/repo#12", "https://github.com/owner/repo/issues/12" or ".../pull/12".
  function ref(input, want) {
    const s = String(input || "").trim();
    let m = /^([\w.-]+)\/([\w.-]+)#(\d+)$/.exec(s);
    if (m) return { owner: m[1], repo: m[2], number: Number(m[3]), kind: want };
    m = /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/(issues|pull)\/(\d+)/.exec(s);
    if (m) return { owner: m[1], repo: m[2], number: Number(m[4]), kind: m[3] === "pull" ? "pull" : "issue" };
    throw new S.SiteError("invalid", `github: expected "owner/repo#123" or an issue or pull request URL, got ${JSON.stringify(input)}`);
  }
  const repoName = (s) => {
    const m = /^(?:https:\/\/github\.com\/)?([\w.-]+\/[\w.-]+?)(?:\.git)?\/?$/.exec(String(s || "").trim());
    if (!m) throw new S.SiteError("invalid", `github: expected "owner/repo", got ${JSON.stringify(s)}`);
    return m[1];
  };

  S.register(
    "github",
    (t) => {
      const issueFn = new Function("arg", `return (${readIssue.toString().replace("(__MD__)", `(${S.ELEMENT_MARKDOWN})`)})(arg);`);
      async function page(r, kind) {
        const url = `${ORIGIN}/${r.owner}/${r.repo}/${kind === "pull" ? "pull" : "issues"}/${r.number}`;
        return t.withTab(url, async (p) => {
          t.assertSignedIn("github", p, SIGN_IN);
          if (/\/404|Page not found/.test(await p.title())) throw new S.SiteError("not_found", `github: ${url} was not found, or this account cannot see it`);
          await t.waitIn(p, () => !!document.querySelector('[data-testid="issue-title"], .js-issue-title, h1'), undefined, { signIn: SIGN_IN, name: "github", what: "the GitHub page" });
          await t.waitIn(p, () => !!document.querySelector('[data-testid="markdown-body"], .js-comment-body, .comment-body'), undefined, { signIn: SIGN_IN, name: "github", timeout: 8000, what: "the issue body" }).catch(() => {});
          return { url: p.url(), ...(await p.evaluate(issueFn)) };
        });
      }
      async function diff(input) {
        const r = ref(input, "pull");
        const res = await t.fetch(`${ORIGIN}/${r.owner}/${r.repo}/pull/${r.number}.diff`);
        if (res.status === 404) throw new S.SiteError("not_found", `github.diff: ${r.owner}/${r.repo}#${r.number} is not a pull request this account can see`);
        if (!res.ok) throw new S.SiteError("http", `github.diff: HTTP ${res.status}`);
        return res.text();
      }
      return {
        // { url, number, title, state, labels, body: { author, createdAt, body }, comments: [...] }
        async issue(input) {
          const r = ref(input, "issue");
          return { number: r.number, ...(await page(r, r.kind || "issue")) };
        },
        // Like issue(); { diff: true } adds the unified diff.
        async pull(input, options = {}) {
          const r = ref(input, "pull");
          const out = { number: r.number, ...(await page(r, "pull")) };
          if (options.diff) out.diff = await diff(input);
          return out;
        },
        diff,
        // [{ number, kind, title, url }] from the repository's issue or pull
        // request list; { query } is GitHub search syntax ("is:open label:bug").
        async issues(repo, options = {}) {
          const name = repoName(repo);
          const kind = options.pulls ? "pulls" : "issues";
          const q = options.query !== undefined ? `?q=${encodeURIComponent(options.query)}` : "";
          return t.withTab(`${ORIGIN}/${name}/${kind}${q}`, async (p) => {
            t.assertSignedIn("github.issues", p, SIGN_IN);
            await t.waitIn(p, (repoPath) => [...document.querySelectorAll("a[href]")].some((a) => new RegExp("/" + repoPath + "/(issues|pull)/\\d+$").test(a.getAttribute("href") || "")) || /No results|There aren.t any|No open|No issues/i.test(document.body.innerText), name, { signIn: SIGN_IN, name: "github", what: "the issue list", timeout: 20000 });
            return p.evaluate(readList, { repo: name, limit: options.limit || 50 });
          });
        },
        // A file's text at a ref: file("owner/repo", "path/to/file", { ref: "main" }).
        async file(repo, filePath, options = {}) {
          const name = repoName(repo);
          const res = await t.fetch(`${ORIGIN}/${name}/raw/${encodeURIComponent(options.ref || "HEAD")}/${String(filePath).split("/").map(encodeURIComponent).join("/")}`);
          if (res.status === 404) throw new S.SiteError("not_found", `github.file: ${name}/${filePath} not found at ${options.ref || "HEAD"}`);
          if (!res.ok) throw new S.SiteError("http", `github.file: HTTP ${res.status}`);
          return res.text();
        },
      };
    },
    { summary: "GitHub issues, pull requests, diffs, files and issue lists (private repos via the session)" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
