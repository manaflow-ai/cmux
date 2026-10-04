// sites.x: X (Twitter) profiles, timelines, search and posts read from the
// rendered pages in a background tab (the data-testid attributes X's web
// app exposes), and posts made through X's documented Web Intent composer
// after a confirmed draft.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const ORIGIN = "https://x.com";
  const SIGN_IN = [/x\.com\/(i\/flow\/login|login|i\/flow\/signup)/, /twitter\.com\/(i\/flow\/login|login)/];

  function readTweets(arg) {
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const count = (label, word) => {
      const m = new RegExp("([\\d,.]+[KMB]?)\\s+" + word, "i").exec(label || "");
      if (!m) return 0;
      const n = parseFloat(m[1].replace(/,/g, ""));
      return Math.round(n * ({ K: 1e3, M: 1e6, B: 1e9 }[m[1].slice(-1).toUpperCase()] || 1));
    };
    const out = [];
    const seen = new Set();
    for (const art of document.querySelectorAll('article[data-testid="tweet"]')) {
      const time = art.querySelector("time");
      const link = time && time.closest("a[href*='/status/']");
      const m = link && /\/([^/]+)\/status\/(\d+)/.exec(link.getAttribute("href"));
      if (!m || seen.has(m[2])) continue;
      seen.add(m[2]);
      const nameBox = art.querySelector('[data-testid="User-Name"]');
      const nameParts = nameBox ? [...nameBox.querySelectorAll("span")].filter((e) => !e.querySelector("span")).map((e) => clean(e.textContent)).filter((t) => t && !t.startsWith("@") && t !== "·") : [];
      const group = art.querySelector('[role="group"][aria-label]');
      const label = group ? group.getAttribute("aria-label") : "";
      const text = art.querySelector('[data-testid="tweetText"]');
      out.push({
        id: m[2],
        url: "https://x.com/" + m[1] + "/status/" + m[2],
        author: { name: nameParts[0] || null, screenName: m[1] },
        text: text ? text.innerText : "",
        createdAt: time.getAttribute("datetime"),
        replies: count(label, "repl"),
        retweets: count(label, "repost"),
        likes: count(label, "like"),
        bookmarks: count(label, "bookmark"),
        views: count(label, "view"),
        media: [...art.querySelectorAll('[data-testid="tweetPhoto"] img')].map((i) => i.src),
      });
      if (out.length >= arg.limit) break;
    }
    return out;
  }

  function readUser() {
    const q = (s) => document.querySelector(s);
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const nameBox = q('[data-testid="UserName"]');
    if (!nameBox) return null;
    const parts = [...nameBox.querySelectorAll("span")].filter((e) => !e.querySelector("span")).map((e) => clean(e.textContent)).filter(Boolean);
    const num = (sel) => {
      const a = q(sel);
      const m = a && /([\d,.]+[KMB]?)/.exec(a.innerText);
      if (!m) return null;
      const n = parseFloat(m[1].replace(/,/g, ""));
      return Math.round(n * ({ K: 1e3, M: 1e6, B: 1e9 }[m[1].slice(-1).toUpperCase()] || 1));
    };
    return {
      name: parts.find((p) => !p.startsWith("@")) || null,
      screenName: (parts.find((p) => p.startsWith("@")) || "").slice(1) || null,
      description: clean((q('[data-testid="UserDescription"]') || {}).innerText) || "",
      location: clean((q('[data-testid="UserLocation"]') || {}).innerText) || null,
      url: clean((q('[data-testid="UserUrl"]') || {}).innerText) || null,
      joined: clean((q('[data-testid="UserJoinDate"]') || {}).innerText) || null,
      followersCount: num('a[href$="/verified_followers"], a[href$="/followers"]'),
      followingCount: num('a[href$="/following"]'),
    };
  }

  // Runs in an x.com page: the signed-in user's id from X's twid cookie
  // (u=<id>), which X's web client reads too; null when signed out.
  function signedInUser() {
    const m = /(?:^|;\s*)twid=([^;]*)/.exec(document.cookie);
    if (!m) return null;
    const id = /u=(\d+)/.exec(decodeURIComponent(m[1]));
    return id ? id[1] : null;
  }

  S.register(
    "x",
    (t) => {
      const handle = (s) => {
        const m = /^(?:https?:\/\/(?:www\.)?(?:x|twitter)\.com\/)?@?(\w{1,15})\/?$/.exec(String(s || "").trim());
        if (!m) throw new S.SiteError("invalid", `x: expected a handle or profile URL, got ${JSON.stringify(s)}`);
        return m[1];
      };
      const statusId = (s) => {
        const m = /(?:status\/)?(\d{1,25})\/?$/.exec(String(s || "").trim());
        if (!m) throw new S.SiteError("invalid", `x: expected a post id or status URL, got ${JSON.stringify(s)}`);
        return m[1];
      };
      async function tweets(url, limit, what) {
        return t.withTab(url, async (page) => {
          t.assertSignedIn("x", page, SIGN_IN);
          await t.waitIn(page, () => !!document.querySelector('article[data-testid="tweet"], [data-testid="emptyState"], [data-testid="error-detail"]'), undefined, { signIn: SIGN_IN, name: "x", what, timeout: 30000 });
          let got = await page.evaluate(readTweets, { limit });
          for (let i = 0; i < 8 && got.length < limit; i++) {
            const before = got.length;
            await page.mouse.wheel(0, 3000);
            await t.sleep(800);
            got = mergeById(got, await page.evaluate(readTweets, { limit: 1000 }), limit);
            if (got.length === before && i > 2) break;
          }
          return got;
        });
      }
      const mergeById = (a, b, limit) => {
        const seen = new Set(a.map((x) => x.id));
        return a.concat(b.filter((x) => !seen.has(x.id))).slice(0, limit);
      };
      return {
        // { name, screenName, description, location, url, joined, followersCount, followingCount }
        async user(who) {
          const h = handle(who);
          return t.withTab(`${ORIGIN}/${h}`, async (page) => {
            t.assertSignedIn("x.user", page, SIGN_IN);
            await t.waitIn(page, () => !!document.querySelector('[data-testid="UserName"], [data-testid="emptyState"], [data-testid="error-detail"]'), undefined, { signIn: SIGN_IN, name: "x", what: "the X profile", timeout: 30000 });
            const u = await page.evaluate(readUser);
            if (!u) throw new S.SiteError("not_found", `x.user: no profile @${h}`);
            return u;
          });
        },
        // Posts: [{ id, url, author, text, createdAt, replies, retweets, likes, bookmarks, views, media }]
        userTweets: (who, options = {}) => tweets(`${ORIGIN}/${handle(who)}`, options.limit || 20, "the X profile timeline"),
        timeline: (options = {}) => tweets(`${ORIGIN}/home`, options.limit || 20, "the X home timeline"),
        search: (query, options = {}) => tweets(`${ORIGIN}/search?q=${encodeURIComponent(query)}&src=typed_query${options.product === "Top" ? "" : "&f=live"}`, options.limit || 20, "X search results"),
        // The post and the replies shown under it.
        tweet: (id, options = {}) => tweets(`${ORIGIN}/i/status/${statusId(id)}`, options.limit || 20, "the X post"),
        // Draft a post, or a reply with { replyTo }. post(draftId, { confirm: true }) publishes it.
        post(input, options) {
          return t.write("x", "post", input, options, async (p) => {
            const spec = typeof p === "string" ? { text: p } : p || {};
            if (typeof spec.text !== "string" || !spec.text.trim()) throw new S.SiteError("invalid", "x.post: expected the post text");
            const replyTo = spec.replyTo ? statusId(spec.replyTo) : null;
            // The draft pins the signed-in account (its user id); X switches
            // accounts in the shared profile, so another session can.
            const account = await t.inOrigin(ORIGIN, signedInUser);
            if (!account) throw new S.SiteError("not_signed_in", "x.post: the cmux browser is not signed in to X (no signed-in user id); open https://x.com with tabs.open() and ask the user to sign in");
            return {
              category: "[9] representational communication (public post)",
              summary: replyTo ? `Reply on X to post ${replyTo} as user ${account}` : `Publish a post on X as user ${account}`,
              preview: { account, text: spec.text, replyTo },
              run: () =>
                t.withTab(`${ORIGIN}/intent/post?text=${encodeURIComponent(spec.text)}${replyTo ? `&in_reply_to=${replyTo}` : ""}`, async (page) => {
                  t.assertSignedIn("x.post", page, SIGN_IN);
                  const button = page.locator('[data-testid="tweetButton"]');
                  await button.first().waitFor({ timeout: 30000 });
                  const now = await page.evaluate(signedInUser);
                  if (now !== account) throw new S.SiteError("account_changed", `x.post: the signed-in X user is now ${now || "nobody"}, not ${account} as drafted; nothing was posted`);
                  const box = page.locator('[data-testid="tweetTextarea_0"]').first();
                  // The whole text, not its start: a page script or another
                  // session could keep the drafted opening and add to it.
                  if (!(await box.count()) || !(await t.composerHolds(box, spec.text))) throw new S.SiteError("compose_mismatch", "x.post: the composer did not receive the drafted text, or holds more than it; nothing was posted");
                  await button.first().click();
                  await t.waitIn(page, () => !document.querySelector('[data-testid="tweetButton"]') || /Your post was sent|Your reply was sent/.test(document.body.innerText), undefined, { signIn: SIGN_IN, name: "x", timeout: 30000, what: "X to publish the post" });
                  return { status: "posted", replyTo };
                }),
            };
          });
        },
      };
    },
    { summary: "X profiles, timelines, search, posts with replies; confirmed-draft posts and replies" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
