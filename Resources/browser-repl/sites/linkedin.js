// sites.linkedin: the viewer and profiles from LinkedIn's Voyager API (the
// one its web app calls, same-origin from a background linkedin.com tab;
// the CSRF value is read from the session cookie inside that page and never
// returned), search results and the feed read from LinkedIn's pages, and
// posts made through LinkedIn's share composer after a confirmed draft.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const ORIGIN = "https://www.linkedin.com";
  const SIGN_IN = [/linkedin\.com\/(login|authwall|checkpoint|uas\/login|signup)/];

  async function voyager(arg) {
    const m = /(?:^|;\s*)JSESSIONID="?([^";]+)"?/.exec(document.cookie);
    if (!m) return { error: "not_signed_in" };
    const r = await fetch(arg.path, { headers: { "csrf-token": m[1], "x-restli-protocol-version": "2.0.0", accept: "application/vnd.linkedin.normalized+json+2.1" }, credentials: "include" });
    let json = null;
    try {
      json = await r.json();
    } catch (e) {}
    return { status: r.status, json };
  }

  // Search result and feed cards, read from the rendered page.
  function readCards(arg) {
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const out = [];
    const seen = new Set();
    if (arg.kind === "feed") {
      const actor = (el) => el.querySelector('a[href*="/in/"], a[href*="/company/"]');
      // Older markup: posts carry their activity URN.
      for (const el of document.querySelectorAll('[data-urn^="urn:li:activity"], [data-id^="urn:li:activity"]')) {
        const urn = el.getAttribute("data-urn") || el.getAttribute("data-id");
        if (seen.has(urn)) continue;
        seen.add(urn);
        const lines = el.innerText.split("\n").map(clean).filter(Boolean);
        const text = el.querySelector(".update-components-text, .feed-shared-update-v2__description, [data-testid='expandable-text-box']");
        const a = actor(el);
        out.push({ id: urn, url: `https://www.linkedin.com/feed/update/${urn}/`, author: a ? clean(a.innerText) : lines[0] || null, authorUrl: a ? new URL(a.getAttribute("href"), location.href).origin + new URL(a.getAttribute("href"), location.href).pathname : null, text: text ? clean(text.innerText) : lines.slice(1, 6).join(" ") });
        if (out.length >= arg.limit) return out;
      }
      // 2026 markup: each post is a list item with a componentkey and an expandable text box.
      for (const el of document.querySelectorAll('main [role="listitem"][componentkey]')) {
        const box = el.querySelector('[data-testid="expandable-text-box"]');
        const key = el.getAttribute("componentkey");
        if (!box || seen.has(key)) continue;
        seen.add(key);
        const a = actor(el);
        const href = a ? new URL(a.getAttribute("href"), location.href) : null;
        out.push({ id: key, url: null, author: a ? clean(a.innerText) : null, authorUrl: href ? href.origin + href.pathname : null, text: clean(box.innerText) });
        if (out.length >= arg.limit) break;
      }
      return out;
    }
    const pattern = arg.kind === "companies" ? /\/company\/[^/?#]+/ : /\/in\/[^/?#]+/;
    for (const a of document.querySelectorAll("main a[href]")) {
      const m = pattern.exec(a.getAttribute("href") || "");
      if (!m || seen.has(m[0])) continue;
      const card = a.closest("li") || a.closest("[data-chameleon-result-urn], [data-view-name]") || a.parentElement;
      const lines = card.innerText.split("\n").map(clean).filter((s) => s && !/^(Connect|Follow|Message|View profile|•|· ?\d\w+)$/i.test(s));
      if (!lines.length) continue;
      seen.add(m[0]);
      out.push({ name: lines[0], url: `https://www.linkedin.com${m[0]}/`, summary: lines.slice(1, 4) });
      if (out.length >= arg.limit) break;
    }
    return out;
  }

  // An author URN as one form for both sides of the check: a member's
  // profile URN (fsd_profile, fs_miniProfile and fs_profile share its id)
  // or a company page's (fsd_company, company, organization,
  // fs_normalized_company and fs_miniCompany share its numeric id).
  // Anything else is null. composerSettings, which runs in the page,
  // keeps its own copy of the same mapping.
  function authorOf(urn) {
    const m = /^urn:li:(fsd_profile|fs_miniProfile|fs_profile|fsd_company|company|organization|fs_normalized_company|fs_miniCompany):([A-Za-z0-9_-]{1,100})$/.exec(String(urn || ""));
    if (!m) return null;
    const person = /profile$/i.test(m[1]);
    return { authorUrn: `urn:li:${person ? "fsd_profile" : "fsd_company"}:${m[2]}`, authorType: person ? "person" : "organization" };
  }

  // The share composer's header, read in the agent's world right before
  // Post: who the post goes out as (the member, or a company page they
  // admin) and its audience, from the control that shows "<name> Post to
  // <audience>", and the author's URN from the attributes inside that
  // control (its actor avatar). Its text is read node by node, at most
  // 400 characters; a header that is missing, ambiguous or longer gives
  // nothing, and a header without exactly one author URN gives no author,
  // so the commit fails closed (target_unverified).
  function composerSettings() {
    const AUTHOR = /urn:li:(?:fsd_profile|fs_miniProfile|fs_profile|fsd_company|company|organization|fs_normalized_company|fs_miniCompany):[A-Za-z0-9_-]{1,100}/g;
    const authorOf = (urn) => {
      const m = /^urn:li:(\w+):(.+)$/.exec(urn);
      const person = /profile$/i.test(m[1]);
      return { authorUrn: `urn:li:${person ? "fsd_profile" : "fsd_company"}:${m[2]}`, authorType: person ? "person" : "organization" };
    };
    const dialog = document.querySelector('div[role="dialog"]');
    if (!dialog) return {};
    const textOf = (el) => {
      let out = "";
      const walker = document.createTreeWalker(el, 4 /* NodeFilter.SHOW_TEXT */);
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        out += n.data;
        if (out.length > 400) return null;
      }
      return out.replace(/\s+/g, " ").trim();
    };
    let found = null;
    let seen = 0;
    const walker = document.createTreeWalker(dialog, 1 /* NodeFilter.SHOW_ELEMENT */);
    for (let el = walker.nextNode(); el && ++seen <= 5000; el = walker.nextNode()) {
      if (el.localName !== "button" || !el.classList.contains("share-unified-settings-entry-button")) continue;
      if (found) return {};
      found = el;
    }
    if (!found || seen > 5000) return {};
    const m = /^(.+?)\s*Post to\s+(.+)$/.exec(textOf(found) || "");
    const urns = new Set();
    let n = 0;
    for (const el of [found, ...found.querySelectorAll("*")]) {
      if (++n > 500) return m ? { postAs: m[1], audience: m[2] } : {};
      for (const a of el.attributes) {
        if (a.value.length > 2000) continue;
        for (const u of a.value.match(AUTHOR) || []) urns.add(authorOf(u).authorUrn);
      }
    }
    const author = urns.size === 1 ? authorOf([...urns][0]) : {};
    return m ? { postAs: m[1], audience: m[2], ...author } : author;
  }

  // The audiences a post can name, as the composer's header shows them.
  const AUDIENCES = { anyone: "Anyone", connections: "Connections only" };
  const settingText = (v) => String(v).replace(/\s+/g, " ").trim().toLowerCase();
  const byType = (json, suffix) => ((json && json.included) || []).filter((x) => typeof x.$type === "string" && x.$type.endsWith(suffix));

  S.register(
    "linkedin",
    (t) => {
      async function api(path) {
        const r = await t.inOrigin(ORIGIN, voyager, { path });
        if (r.error || r.status === 401 || r.status === 403) throw new S.SiteError("not_signed_in", "linkedin: the cmux browser is not signed in to LinkedIn; open https://www.linkedin.com with tabs.open() and ask the user to sign in");
        if (r.status < 200 || r.status >= 300 || !r.json) throw new S.SiteError("http", `linkedin: HTTP ${r.status} for ${path}`);
        return r.json;
      }
      const identifier = (s) => {
        const m = /linkedin\.com\/in\/([^/?#]+)/.exec(String(s));
        const id = m ? decodeURIComponent(m[1]) : String(s || "").trim();
        if (!id || /[/?#\s]/.test(id)) throw new S.SiteError("invalid", `linkedin: expected a public profile identifier or /in/ URL, got ${JSON.stringify(s)}`);
        return id;
      };
      async function cards(url, kind, limit) {
        return t.withTab(url, async (page) => {
          t.assertSignedIn("linkedin", page, SIGN_IN);
          await t.waitIn(page, (k) => (k === "feed" ? !!document.querySelector('[data-urn^="urn:li:activity"], [data-id^="urn:li:activity"], main [role="listitem"] [data-testid="expandable-text-box"]') : !!document.querySelector("main a[href*='/in/'], main a[href*='/company/']") || /No results/i.test(document.body.innerText)), kind, { signIn: SIGN_IN, name: "linkedin", what: "LinkedIn results", timeout: 30000 });
          let got = await page.evaluate(readCards, { kind, limit });
          for (let i = 0; i < 6 && got.length < limit; i++) {
            await page.mouse.wheel(0, 2400);
            await t.sleep(700);
            got = await page.evaluate(readCards, { kind, limit });
          }
          return got;
        });
      }
      const viewer = (json) => {
        const mini = byType(json, "MiniProfile")[0] || {};
        return { id: (json && json.data && json.data.plainId) || null, publicIdentifier: mini.publicIdentifier || null, firstName: mini.firstName || null, lastName: mini.lastName || null, headline: mini.occupation || null, url: mini.publicIdentifier ? `${ORIGIN}/in/${mini.publicIdentifier}/` : null };
      };
      // { id, publicIdentifier, firstName, lastName, headline, url }
      async function me() {
        return viewer(await api("/voyager/api/me"));
      }
      return {
        me,
        // { publicIdentifier, firstName, lastName, headline, location, url }
        async profile(who) {
          const id = identifier(who);
          const json = await api(`/voyager/api/identity/dash/profiles?q=memberIdentity&memberIdentity=${encodeURIComponent(id)}&decorationId=com.linkedin.voyager.dash.deco.identity.profile.WebTopCardCore-16`);
          const p = byType(json, "identity.profile.Profile").find((x) => x.publicIdentifier === id) || byType(json, "identity.profile.Profile")[0];
          if (!p) throw new S.SiteError("not_found", `linkedin.profile: no profile ${id}`);
          const geo = p.geoLocation && p.geoLocation.geo;
          return { publicIdentifier: p.publicIdentifier, firstName: p.firstName, lastName: p.lastName, headline: p.headline || null, location: (geo && geo.defaultLocalizedName) || (p.location && p.location.defaultLocalizedName) || null, url: `${ORIGIN}/in/${p.publicIdentifier}/` };
        },
        // [{ name, url, summary }]; type "people" (default) or "companies".
        search(query, options = {}) {
          const type = options.type || "people";
          if (!["people", "companies"].includes(type)) throw new S.SiteError("invalid", `linkedin.search: type: expected people or companies, got ${JSON.stringify(type)}`);
          return cards(`${ORIGIN}/search/results/${type}/?keywords=${encodeURIComponent(query)}`, type, options.limit || 10);
        },
        // [{ id, url, author, authorUrl, text }] from the home feed (url when the markup carries the activity URN).
        feed(options = {}) {
          return cards(`${ORIGIN}/feed/`, "feed", options.limit || 10);
        },
        // Draft a post as the signed-in member: post({ text, audience }),
        // audience "anyone" or "connections", always named (a public post
        // is an explicit choice). post(draftId, { confirm: true }) publishes it.
        post(input, options) {
          return t.write("linkedin", "post", input, options, async (p) => {
            const spec = typeof p === "string" ? { text: p } : p || {};
            const text = spec.text;
            if (typeof text !== "string" || !text.trim()) throw new S.SiteError("invalid", "linkedin.post: expected the post text");
            const audience = typeof spec.audience === "string" && Object.prototype.hasOwnProperty.call(AUDIENCES, spec.audience) ? AUDIENCES[spec.audience] : null;
            if (!audience) throw new S.SiteError("invalid", spec.audience === undefined ? 'linkedin.post: name the audience: post({ text, audience: "anyone" }) for a public post, or audience: "connections" for connections only' : `linkedin.post: audience: expected "anyone" or "connections", got ${JSON.stringify(spec.audience)}`);
            // The draft pins the signed-in member (its immutable member id
            // and public identifier); another session can sign in as
            // someone else before the confirmation.
            const meJSON = await api("/voyager/api/me");
            const who = viewer(meJSON);
            const account = who.publicIdentifier;
            const memberId = who.id;
            if (!account || !memberId) throw new S.SiteError("not_signed_in", "linkedin.post: could not tell which LinkedIn member is signed in");
            // The author by URN and type (a person, never an organization):
            // a company page they admin can carry the member's very name.
            const mini = byType(meJSON, "MiniProfile")[0] || {};
            const author = authorOf(mini.entityUrn || (meJSON && meJSON.data && meJSON.data["*miniProfile"]));
            if (!author || author.authorType !== "person") throw new S.SiteError("not_signed_in", "linkedin.post: could not tell the signed-in member's profile URN, which the share composer's header names as its author");
            // The target: the post goes out as the member (not a company
            // page they admin), by the author URN and type and the name the
            // composer's header shows, to `audience`. The composer keeps LinkedIn's last choice of
            // both, which another session can change.
            const postAs = [who.firstName, who.lastName].filter(Boolean).join(" ");
            if (!postAs) throw new S.SiteError("not_signed_in", "linkedin.post: could not tell the signed-in member's name, which the share composer shows as who it posts as");
            return {
              category: "[9] representational communication (public post)",
              summary: `Publish a LinkedIn post as ${account} to ${audience} (${text.length} characters)`,
              account: { account, memberId },
              target: { postAs, authorUrn: author.authorUrn, authorType: author.authorType, audience },
              content: { text },
              canon: { text: t.normText, postAs: settingText, audience: settingText },
              commit: (c) =>
                t.withTab(`${ORIGIN}/feed/?shareActive=true&text=${encodeURIComponent(text)}`, async (page) => {
                  t.assertSignedIn("linkedin.post", page, SIGN_IN);
                  const box = page.locator('div[role="dialog"] div[role="textbox"]').first();
                  await box.waitFor({ timeout: 30000 });
                  // The member this composer page posts as, read in that
                  // page (its own session cookie), its header's identity
                  // and audience, and the whole text it holds, right
                  // before Post: the profile can switch
                  // accounts while the composer loads. The member is read
                  // once more as the last read before the click; a switch
                  // between that read and the click is the remaining window
                  // (LinkedIn has no post bound to a member).
                  const memberNow = async () => {
                    const r = await t.readBack(page, voyager, { path: "/voyager/api/me" });
                    const now = r && r.status >= 200 && r.status < 300 && r.json ? viewer(r.json) : null;
                    return { ...(now && now.publicIdentifier ? { account: now.publicIdentifier } : {}), ...(now && now.id ? { memberId: now.id } : {}) };
                  };
                  return c.write(
                    async () => ({ ...(await memberNow()), ...(await t.readBack(page, composerSettings)), text: await t.composerText(box) }),
                    async (press) => {
                      await press();
                      await t.waitIn(page, () => !document.querySelector('div[role="dialog"] div[role="textbox"]'), undefined, { signIn: SIGN_IN, name: "linkedin", timeout: 30000, what: "LinkedIn to publish the post" });
                      return { status: "posted" };
                    },
                    // The Post button itself, never the header's "Post to …" control.
                    { submit: page.locator('div[role="dialog"] button.share-actions__primary-action, div[role="dialog"] button:text-is("Post")').first(), account: memberNow },
                  );
                }),
            };
          });
        },
      };
    },
    { summary: "LinkedIn viewer, profiles, people/company search, feed; confirmed-draft posts", writes: ["post"] },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
