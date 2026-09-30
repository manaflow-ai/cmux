// sites.googleSearch: structured Google web results, read from the results
// page in a background tab of the signed-in browser. Searches run one at a
// time with a short gap, since bursts make Google show a CAPTCHA.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URLSearchParams } = root.CmuxBrowserRepl.core;
  const GAP_MS = 1200;

  // Runs in the results page. Blocks are div[data-rpos] (stable attributes,
  // not generated class names); the title link is the external link around
  // an h3.
  function readResults(arg) {
    if (/\/sorry\//.test(location.pathname) || document.querySelector("form#captcha-form, #recaptcha")) return { blocked: true };
    const external = (a) => {
      try {
        let u = new URL(a.href, location.href);
        if (/(^|\.)google\.[a-z.]+$/.test(u.hostname) && u.pathname === "/url") u = new URL(u.searchParams.get("q") || u.searchParams.get("url") || "", location.href);
        if (!/^https?:$/.test(u.protocol)) return null;
        if (/(^|\.)google\.[a-z.]+$/.test(u.hostname) && !/^(docs|sites|developers|support|cloud|blog)\./.test(u.hostname)) return null;
        return u.href;
      } catch (e) {
        return null;
      }
    };
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    let blocks = [...document.querySelectorAll("#search div[data-rpos], #rso div[data-rpos]")].filter((b) => !b.parentElement.closest("div[data-rpos]"));
    if (!blocks.length) blocks = [...document.querySelectorAll("#rso a h3, #search a h3")].map((h) => h.closest("#rso > div, #search div.g") || h.closest("a").parentElement);
    const results = [];
    const seen = new Set();
    for (const b of blocks) {
      const h3 = b.querySelector("a h3");
      const a = h3 && h3.closest("a");
      const url = a && external(a);
      if (!url || seen.has(url)) continue;
      seen.add(url);
      const r = { title: clean(h3.textContent), url };
      const cite = a.querySelector("cite");
      const site = [...a.querySelectorAll("span")].map((s) => clean(s.textContent)).find((s) => s && s !== r.title && !(cite && cite.textContent.includes(s)) && !/^https?:\/\//.test(s));
      if (site) r.sourceName = site;
      const snippetEl = b.querySelector("[data-sncf], [data-snf]") || [...b.querySelectorAll("div, span")].reverse().find((d) => !d.contains(a) && !a.contains(d) && clean(d.textContent).length > 40 && d.children.length < 6);
      let snippet = snippetEl ? clean(snippetEl.textContent) : "";
      const dated = /^(\d+ (?:seconds?|minutes?|hours?|days?|weeks?|months?|years?) ago|[A-Z][a-z]{2} \d{1,2}, \d{4})\s+[—-]\s+/.exec(snippet);
      if (dated) {
        r.publishedAtText = dated[1];
        snippet = snippet.slice(dated[0].length);
      }
      if (snippet) r.snippet = snippet;
      const links = [...b.querySelectorAll("a[href]")].filter((x) => x !== a && clean(x.textContent) && !x.querySelector("h3")).map((x) => ({ title: clean(x.textContent), url: external(x) })).filter((x) => x.url && x.url !== url && x.title.length < 80);
      if (links.length) r.sitelinks = links.slice(0, 6);
      results.push(r);
      if (results.length >= arg.limit) break;
    }
    return { results };
  }

  S.register(
    "googleSearch",
    (t) => {
      let queue = Promise.resolve();
      let last = 0;
      return {
        // [{ title, url, sourceName, publishedAtText, snippet, sitelinks }].
        // Options: limit (10), start (offset: 10 = page 2), language ("en"),
        // country ("us"), safeSearch ("active" | "off"), time ("day" | "week" | "month" | "year").
        search(query, options = {}) {
          if (!query || typeof query !== "string") throw new S.SiteError("invalid", `googleSearch.search: query: expected a string, got ${JSON.stringify(query)}`);
          const limit = options.limit === undefined ? 10 : options.limit;
          if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new S.SiteError("invalid", `googleSearch.search: limit: expected 1 to 100, got ${JSON.stringify(limit)}`);
          const times = { day: "d", week: "w", month: "m", year: "y" };
          if (options.time !== undefined && !times[options.time]) throw new S.SiteError("invalid", `googleSearch.search: time: expected day, week, month or year, got ${JSON.stringify(options.time)}`);
          const q = new URLSearchParams({ q: query, hl: options.language || "en" });
          if (options.country) q.set("gl", options.country);
          if (options.start) q.set("start", String(options.start));
          if (limit > 10) q.set("num", String(limit));
          if (options.safeSearch) q.set("safe", options.safeSearch === "off" ? "off" : "active");
          if (options.time) q.set("tbs", `qdr:${times[options.time]}`);
          const run = async () => {
            const wait = last + GAP_MS - t.now();
            if (wait > 0) await t.sleep(wait);
            try {
              return await t.withTab(`https://www.google.com/search?${q}`, async (page) => {
                await t.waitIn(page, () => !!(document.querySelector("#search, #rso, form#captcha-form, #recaptcha") || /\/sorry\//.test(location.pathname)), undefined, { what: "Google results" });
                const r = await page.evaluate(readResults, { limit });
                if (r.blocked) throw new S.SiteError("captcha", "googleSearch.search: Google showed a CAPTCHA (unusual traffic). cmux does not solve CAPTCHAs; open https://www.google.com/search with tabs.open() and let the user answer it, then retry.");
                return r.results;
              });
            } finally {
              last = t.now();
            }
          };
          const p = queue.then(run, run);
          queue = p.catch(() => {});
          return p;
        },
      };
    },
    { summary: "Structured Google web results (sequential, CAPTCHA reported, never solved)" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
