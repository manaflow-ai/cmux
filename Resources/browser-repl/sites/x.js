// sites.x: X (Twitter) profiles, timelines, search and posts read from the
// rendered pages in a background tab (the data-testid attributes X's web
// app exposes), and posts made through X's documented Web Intent composer
// after a confirmed draft.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL } = root.CmuxBrowserRepl.core;
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

  // The bearer token X's web client sends with its own API calls. It is
  // public (it ships in X's web app script) and names the web app, not a
  // user: the user is the one X's HttpOnly session cookie authenticates.
  const WEB_BEARER = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";

  // Runs in an x.com page: the screen name of the account X authenticates
  // this browser as, from the account settings endpoint X's web client
  // calls (the session cookie, the bearer token and the ct0 CSRF value);
  // null when X does not answer with one. Not the twid cookie, which names
  // a user id but which any page script, another session's too, can write.
  async function authenticatedUser(arg) {
    const csrf = /(?:^|;\s*)ct0=([^;]+)/.exec(document.cookie);
    if (!csrf) return null;
    try {
      const r = await fetch("/i/api/1.1/account/settings.json", {
        credentials: "include",
        headers: { authorization: "Bearer " + arg.bearer, "x-csrf-token": decodeURIComponent(csrf[1]), "x-twitter-auth-type": "OAuth2Session", "x-twitter-active-user": "yes" },
      });
      if (!r.ok) return null;
      const body = await r.json();
      return body && typeof body.screen_name === "string" && /^\w{1,15}$/.test(body.screen_name) ? body.screen_name : null;
    } catch (e) {
      return null;
    }
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
            // The draft pins the account X authenticates (its screen name);
            // X switches accounts in the shared profile, so another session
            // can.
            const account = await t.inOrigin(ORIGIN, authenticatedUser, { bearer: WEB_BEARER });
            if (!account) throw new S.SiteError("account_unknown", "x.post: X did not say which X account the cmux browser is signed in as; nothing was drafted. If it is signed out, open https://x.com with tabs.open() and ask the user to sign in");
            return {
              category: "[9] representational communication (public post)",
              summary: replyTo ? `Reply on X to post ${replyTo} as @${account}` : `Publish a post on X as @${account}`,
              account: { account },
              target: { replyTo },
              content: { text: spec.text },
              canon: { text: t.normText, account: (v) => String(v).toLowerCase() },
              commit: (c) =>
                t.withTab(`${ORIGIN}/intent/post?text=${encodeURIComponent(spec.text)}${replyTo ? `&in_reply_to=${replyTo}` : ""}`, async (page) => {
                  t.assertSignedIn("x.post", page, SIGN_IN);
                  const button = page.locator('[data-testid="tweetButton"]');
                  await button.first().waitFor({ timeout: 30000 });
                  const box = page.locator('[data-testid="tweetTextarea_0"]').first();
                  // The account X authenticates (read from this page: another
                  // session can switch accounts while the composer loads),
                  // the post it answers (the composer's own URL) and the
                  // whole text the composer holds, right before Post; the
                  // account once more as the last read before the click.
                  const accountNow = async () => {
                    const now = await t.readBack(page, authenticatedUser, { bearer: WEB_BEARER });
                    return now ? { account: now } : {};
                  };
                  return c.write(
                    async () => {
                      const now = await accountNow();
                      let answers;
                      try {
                        answers = new URL(page.url()).searchParams.get("in_reply_to");
                      } catch (e) {}
                      return { ...now, ...(answers !== undefined ? { replyTo: answers } : {}), ...((await box.count()) ? { text: await t.composerText(box) } : {}) };
                    },
                    async (press) => {
                      await press();
                      await t.waitIn(page, () => !document.querySelector('[data-testid="tweetButton"]') || /Your post was sent|Your reply was sent/.test(document.body.innerText), undefined, { signIn: SIGN_IN, name: "x", timeout: 30000, what: "X to publish the post" });
                      return { status: "posted", replyTo };
                    },
                    // The account again, last, right before the click.
                    { submit: button.first(), account: accountNow },
                  );
                }),
            };
          });
        },
      };
    },
    { summary: "X profiles, timelines, search, posts with replies; confirmed-draft posts and replies", writes: ["post"] },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
