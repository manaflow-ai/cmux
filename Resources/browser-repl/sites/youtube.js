// sites.youtube: search, metadata, captions/transcripts and comments from
// YouTube's own pages and InnerTube endpoints, fetched in the signed-in
// session. When a caption track needs a player-issued token, the transcript
// is read the way the player reads it: a muted background tab turns captions
// on and the page fetches the caption URL the player requested.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL, URLSearchParams } = root.CmuxBrowserRepl.core;
  const ORIGIN = "https://www.youtube.com";

  function videoId(input, name) {
    const s = String(input || "").trim();
    if (/^[\w-]{11}$/.test(s)) return s;
    let u;
    try {
      u = new URL(s);
    } catch {
      u = null;
    }
    if (u && /(^|\.)youtube\.com$|^youtube-nocookie\.com$|(^|\.)youtube-nocookie\.com$/.test(u.hostname)) {
      if (u.searchParams.get("v")) return u.searchParams.get("v");
      const m = /^\/(?:shorts|live|embed|v)\/([\w-]{11})/.exec(u.pathname);
      if (m) return m[1];
    }
    if (u && u.hostname === "youtu.be" && /^\/[\w-]{11}/.test(u.pathname)) return u.pathname.slice(1, 12);
    throw new S.SiteError("invalid", `${name}: expected a YouTube video URL or 11-character id, got ${JSON.stringify(input)}`);
  }

  const text = (v) => (!v ? "" : typeof v === "string" ? v : v.simpleText !== undefined ? v.simpleText : Array.isArray(v.runs) ? v.runs.map((r) => r.text).join("") : v.content !== undefined ? v.content : "");
  const bestThumb = (list) => (Array.isArray(list) && list.length ? list.reduce((a, b) => ((b.width || 0) > (a.width || 0) ? b : a)).url : undefined);
  const num = (s) => {
    const m = /[\d,.]+/.exec(String(s || "").replace(/,/g, ""));
    return m ? Number(m[0]) : undefined;
  };
  const clock = (sec) => {
    const s = Math.floor(sec);
    const h = Math.floor(s / 3600);
    const mm = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
    const ss = String(s % 60).padStart(2, "0");
    return h ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
  };
  function* walk(node, key) {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) {
      for (const n of node) yield* walk(n, key);
      return;
    }
    for (const [k, v] of Object.entries(node)) {
      if (k === key) yield v;
      else yield* walk(v, key);
    }
  }

  // The in-tab transcript path runs as several short page calls (a long
  // call can lose its completion when YouTube's player reshuffles the page):
  // captureStart hooks XHR and fetch in the page world and turns captions on
  // in the muted player; captureRead returns what the player received;
  // captureStop restores the page and returns the caption URLs it saw.
  const CAPTURE = "Symbol.for('cmux.sites.youtube.capture')";
  const captureStart = new Function("arg", `
    const player = document.getElementById("movie_player");
    if (!player || typeof player.getVideoData !== "function") return { error: "the YouTube player did not load" };
    const matches = (name) => {
      try {
        const u = new URL(name, location.href);
        return u.pathname === "/api/timedtext" && u.searchParams.get("v") === arg.videoId && (!arg.lang || u.searchParams.get("lang") === arg.lang || u.searchParams.get("tlang") === arg.lang);
      } catch (e) {
        return false;
      }
    };
    const state = { bodies: [], urls: [], open: XMLHttpRequest.prototype.open, fetch: window.fetch };
    window[${CAPTURE}] = state;
    XMLHttpRequest.prototype.open = function (method, url) {
      if (matches(String(url)))
        this.addEventListener("load", () => {
          try {
            const r = this.response;
            const body = this.responseType === "" || this.responseType === "text" ? this.responseText : r instanceof ArrayBuffer ? new TextDecoder().decode(r) : r && typeof r === "object" ? JSON.stringify(r) : "";
            if (body) state.bodies.push(body);
          } catch (e) {}
        });
      return state.open.apply(this, arguments);
    };
    window.fetch = function (input) {
      const p = state.fetch.apply(this, arguments);
      const url = typeof input === "string" ? input : input && input.url;
      if (url && matches(url)) p.then((r) => r.clone().text()).then((t) => t && state.bodies.push(t), () => {});
      return p;
    };
    // YouTube clears the resource timing buffer; observe entries as they arrive.
    state.observer = new PerformanceObserver((list) => {
      for (const e of list.getEntries()) if (matches(e.name)) state.urls.push(e.name);
    });
    state.observer.observe({ type: "resource", buffered: true });
    try {
      if (player.mute) player.mute();
      if (arg.play && player.playVideo) player.playVideo();
      if (player.toggleSubtitlesOn) player.toggleSubtitlesOn();
      else if (player.toggleSubtitles) player.toggleSubtitles();
      if (arg.lang && player.setOption) player.setOption("captions", "track", { languageCode: arg.lang });
    } catch (e) {}
    return { ok: true };
  `);
  const captureRead = new Function(`const s = window[${CAPTURE}]; return s && s.bodies.length ? s.bodies : null;`);
  const capturePlay = new Function(`const p = document.getElementById("movie_player"); if (p && p.mute) p.mute(); if (p && p.playVideo) p.playVideo(); return true;`);
  const captureStop = new Function(`
    const s = window[${CAPTURE}];
    const p = document.getElementById("movie_player");
    try { if (p && p.pauseVideo) p.pauseVideo(); } catch (e) {}
    if (!s) return { bodies: [], urls: [] };
    XMLHttpRequest.prototype.open = s.open;
    window.fetch = s.fetch;
    s.observer.disconnect();
    delete window[${CAPTURE}];
    return { bodies: s.bodies, urls: s.urls };
  `);
  // Fetches a caption URL in the page (same origin, the player's cookies).
  async function fetchInPage(arg) {
    const r = await fetch(arg.url, { credentials: "include" });
    return r.ok ? r.text() : "";
  }

  // json3, srv3 or legacy XML caption text -> [{ start, duration, text }].
  // Parsed by pattern: YouTube's Trusted Types policy blocks DOMParser there,
  // and the REPL has no DOM.
  function parseCaptions(body) {
    const clean = (x) => x.replace(/\s+/g, " ").trim();
    try {
      const json = JSON.parse(body);
      return (json.events || []).map((ev) => ({ start: (ev.tStartMs || 0) / 1000, duration: (ev.dDurationMs || 0) / 1000, text: clean((ev.segs || []).map((x) => x.utf8 || "").join("")) })).filter((x) => x.text);
    } catch (e) {}
    const decode = (x) => S.decodeEntities(x.replace(/<[^>]*>/g, ""));
    const attr = (attrs, name) => {
      const m = new RegExp("\\b" + name + '="([^"]*)"').exec(attrs);
      return m ? Number(m[1]) : 0;
    };
    const out = [];
    for (const m of body.matchAll(/<p\b([^>]*)>([\s\S]*?)<\/p>/g)) out.push({ start: attr(m[1], "t") / 1000, duration: attr(m[1], "d") / 1000, text: clean(decode(m[2])) });
    if (!out.length) for (const m of body.matchAll(/<text\b([^>]*)>([\s\S]*?)<\/text>/g)) out.push({ start: attr(m[1], "start"), duration: attr(m[1], "dur"), text: clean(decode(decode(m[2]))) });
    return out.filter((x) => x.text);
  }

  S.register(
    "youtube",
    (t) => {
      async function page(path, name, query = {}) {
        // app=desktop: the REPL's fetch otherwise gets the mobile site.
        const q = new URLSearchParams({ hl: "en", app: "desktop", persist_app: "1", ...query });
        const url = `${ORIGIN}${path}${path.includes("?") ? "&" : "?"}${q}`;
        const r = await t.fetch(url);
        if (/consent\.(youtube|google)\.com/.test(r.url)) throw new S.SiteError("consent_required", `${name}: YouTube shows a cookie consent page in this browser; open ${ORIGIN} with tabs.open() and let the user answer it`);
        if (!r.ok) throw new S.SiteError("http", `${name}: YouTube returned HTTP ${r.status} for ${url}`);
        return r.text();
      }
      async function watch(id, name, options = {}) {
        const html = await page(`/watch?v=${id}&has_verified=1&bpctr=9999999999`, name, options.region ? { gl: options.region } : {});
        const player = S.embeddedJSON(html, "ytInitialPlayerResponse = ");
        if (!player) throw new S.SiteError("unexpected", `${name}: the watch page for ${id} had no player data`);
        const status = player.playabilityStatus && player.playabilityStatus.status;
        if (status && status !== "OK" && !player.videoDetails) throw new S.SiteError("unavailable", `${name}: video ${id} is ${status.toLowerCase()}: ${player.playabilityStatus.reason || ""}`.trim());
        return { html, player };
      }
      function metadataOf(id, player) {
        const d = player.videoDetails || {};
        const mf = (player.microformat && player.microformat.playerMicroformatRenderer) || {};
        return {
          videoId: id,
          url: `${ORIGIN}/watch?v=${id}`,
          title: d.title || text(mf.title),
          channelName: d.author || mf.ownerChannelName,
          channelId: d.channelId || mf.externalChannelId,
          channelUrl: (mf.ownerProfileUrl && mf.ownerProfileUrl.replace(/^http:/, "https:")) || (d.channelId ? `${ORIGIN}/channel/${d.channelId}` : undefined),
          durationSeconds: num(d.lengthSeconds),
          viewCount: num(d.viewCount),
          publishDate: mf.publishDate ? String(mf.publishDate).slice(0, 10) : undefined,
          category: mf.category,
          isLiveContent: !!d.isLiveContent,
          keywords: d.keywords || [],
          description: d.shortDescription || text(mf.description),
          thumbnailUrl: bestThumb(d.thumbnail && d.thumbnail.thumbnails),
        };
      }
      function tracksOf(player) {
        const list = player.captions && player.captions.playerCaptionsTracklistRenderer && player.captions.playerCaptionsTracklistRenderer.captionTracks;
        return (list || []).map((c) => ({ lang: c.languageCode, name: text(c.name), auto: c.kind === "asr", baseUrl: c.baseUrl }));
      }
      function segmentsOf(json3) {
        const out = [];
        for (const ev of (json3 && json3.events) || []) {
          const s = (ev.segs || []).map((x) => x.utf8 || "").join("").replace(/\s+/g, " ").trim();
          if (s) out.push({ start: (ev.tStartMs || 0) / 1000, duration: (ev.dDurationMs || 0) / 1000, text: s });
        }
        return out;
      }
      function innertube(html) {
        const key = /"INNERTUBE_API_KEY":"([^"]+)"/.exec(html);
        const version = /"INNERTUBE_CLIENT_VERSION":"([^"]+)"/.exec(html);
        return { key: key && key[1], version: (version && version[1]) || "2.20250101.00.00" };
      }

      const api = {
        videoId: (input) => videoId(input, "youtube.videoId"),
        // [{ videoId, url, title, channelName, channelUrl, duration, views, published, thumbnailUrl }]
        async search(query, options = {}) {
          if (!query || typeof query !== "string") throw new S.SiteError("invalid", `youtube.search: query: expected a string, got ${JSON.stringify(query)}`);
          const limit = options.limit === undefined ? 10 : options.limit;
          const html = await page(`/results?search_query=${encodeURIComponent(query)}&sp=EgIQAQ%253D%253D`, "youtube.search", { ...(options.lang ? { hl: options.lang } : {}), ...(options.region ? { gl: options.region } : {}) });
          const data = S.embeddedJSON(html, "ytInitialData = ");
          if (!data) throw new S.SiteError("unexpected", "youtube.search: the results page had no ytInitialData");
          const out = [];
          const seen = new Set();
          const renderers = [...walk(data, "videoRenderer"), ...walk(data, "videoWithContextRenderer"), ...walk(data, "compactVideoRenderer")];
          for (const v of renderers) {
            if (!v || !v.videoId || seen.has(v.videoId)) continue;
            seen.add(v.videoId);
            const owner = v.ownerText || v.longBylineText || v.shortBylineText;
            const nav = owner && owner.runs && owner.runs[0] && owner.runs[0].navigationEndpoint;
            const channelPath = nav && nav.commandMetadata && nav.commandMetadata.webCommandMetadata && nav.commandMetadata.webCommandMetadata.url;
            out.push({
              videoId: v.videoId,
              url: `${ORIGIN}/watch?v=${v.videoId}`,
              title: text(v.title || v.headline),
              channelName: text(owner) || undefined,
              channelUrl: channelPath ? ORIGIN + channelPath : undefined,
              duration: text(v.lengthText) || undefined,
              views: text(v.viewCountText || v.shortViewCountText) || undefined,
              published: text(v.publishedTimeText) || undefined,
              thumbnailUrl: bestThumb(v.thumbnail && v.thumbnail.thumbnails),
            });
            if (out.length >= limit) break;
          }
          return out;
        },
        async metadata(video, options = {}) {
          const id = videoId(video, "youtube.metadata");
          const { player } = await watch(id, "youtube.metadata", options);
          return metadataOf(id, player);
        },
        // Caption tracks: [{ lang, name, auto }].
        async captions(video) {
          const id = videoId(video, "youtube.captions");
          const { player } = await watch(id, "youtube.captions");
          return tracksOf(player).map(({ lang, name, auto }) => ({ lang, name, auto }));
        },
        // The transcript as text. { lang } picks a track (default: the
        // first human-made track, else the automatic one); { timestamps: true }
        // prints "[mm:ss] text" lines; { format: "segments" } returns
        // [{ start, duration, text }] (seconds).
        async transcript(video, options = {}) {
          const id = videoId(video, "youtube.transcript");
          const { player } = await watch(id, "youtube.transcript");
          const tracks = tracksOf(player);
          if (!tracks.length) throw new S.SiteError("no_captions", `youtube.transcript: video ${id} has no captions`);
          const track = options.lang ? tracks.find((c) => c.lang === options.lang) : tracks.find((c) => !c.auto) || tracks[0];
          if (!track) throw new S.SiteError("no_captions", `youtube.transcript: video ${id} has no ${options.lang} captions; available: ${tracks.map((c) => c.lang + (c.auto ? " (auto)" : "")).join(", ")}`);
          let segments = [];
          try {
            const r = await t.fetch(new URL(track.baseUrl, ORIGIN).href + "&fmt=json3");
            const body = r.ok ? await r.text() : "";
            if (body.trim()) segments = segmentsOf(JSON.parse(body));
          } catch (e) {}
          if (!segments.length) {
            const timeout = options.timeout || 12000;
            segments = await t.withTab(`${ORIGIN}/watch?v=${id}`, async (p) => {
              await t.waitIn(p, () => { const pl = document.getElementById("movie_player"); return !!(pl && typeof pl.getVideoData === "function"); }, undefined, { timeout: 20000, what: "the YouTube player", name: "youtube.transcript" });
              const started = await p.evaluate(captureStart, { videoId: id, lang: track.lang });
              if (started.error) throw new S.SiteError("no_captions", `youtube.transcript: ${started.error}`);
              let stopped = null;
              try {
                // Some players load captions only while playing: play muted after a moment.
                let got = await t.waitIn(p, captureRead, undefined, { timeout: Math.min(4000, timeout), what: "the player's captions", name: "youtube.transcript" }).catch(() => null);
                if (!got) {
                  await p.evaluate(capturePlay);
                  got = await t.waitIn(p, captureRead, undefined, { timeout, what: "the player's captions", name: "youtube.transcript" }).catch(() => null);
                }
              } finally {
                stopped = await p.evaluate(captureStop).catch(() => ({ bodies: [], urls: [] }));
              }
              for (const body of stopped.bodies) {
                const parsed = parseCaptions(body);
                if (parsed.length) return parsed;
              }
              // Last resort: the caption URL the player requested, as json3, then as sent.
              const url = stopped.urls[stopped.urls.length - 1];
              if (!url) throw new S.SiteError("no_captions", `youtube.transcript: the player did not load captions for ${id}`);
              for (const u of [url.replace(/([?&])fmt=[^&]*/, "$1fmt=json3").replace(/^(?!.*[?&]fmt=)(.*)$/, "$1&fmt=json3"), url]) {
                const parsed = parseCaptions(await p.evaluate(fetchInPage, { url: u }).catch(() => ""));
                if (parsed.length) return parsed;
              }
              throw new S.SiteError("no_captions", `youtube.transcript: the caption response for ${id} was empty`);
            });
          }
          if (options.format === "segments") return segments;
          if (options.timestamps) return segments.map((s) => `[${clock(s.start)}] ${s.text}`).join("\n");
          return segments.map((s) => s.text).join(" ").replace(/\s+/g, " ").trim();
        },
        // { videoId, comments: [{ id, url, author, authorUrl, text, published, likes, replies }], continuation }
        async comments(video, options = {}) {
          const id = videoId(video, "youtube.comments");
          const limit = options.limit === undefined ? 20 : options.limit;
          const html = await page(`/watch?v=${id}`, "youtube.comments");
          const { key, version } = innertube(html);
          let token = options.continuation;
          if (!token) {
            const data = S.embeddedJSON(html, "ytInitialData = ");
            for (const section of walk(data, "itemSectionRenderer")) {
              if (section && section.sectionIdentifier === "comment-item-section") {
                for (const c of walk(section, "continuationCommand")) if (c && c.token) token = token || c.token;
              }
            }
            if (!token) for (const c of walk(data, "continuationCommand")) if (c && c.token && /comment/i.test(JSON.stringify(c.request || "")) ) token = token || c.token;
          }
          const comments = [];
          let next = null;
          while (token && comments.length < limit) {
            const r = await t.fetch(`${ORIGIN}/youtubei/v1/next?prettyPrint=false${key ? `&key=${key}` : ""}`, {
              method: "POST",
              headers: { "content-type": "application/json", "x-youtube-client-name": "1", "x-youtube-client-version": version },
              body: JSON.stringify({ context: { client: { clientName: "WEB", clientVersion: version, hl: options.lang || "en", gl: options.region || "US" } }, continuation: token }),
            });
            if (!r.ok) throw new S.SiteError("http", `youtube.comments: HTTP ${r.status}`);
            const data = await r.json();
            const entities = new Map();
            for (const m of walk(data, "commentEntityPayload")) if (m && m.key) entities.set(m.key, m);
            token = null;
            for (const items of walk(data, "continuationItems")) {
              for (const item of items || []) {
                const thread = item.commentThreadRenderer;
                if (thread && comments.length < limit) {
                  const vm = thread.commentViewModel && (thread.commentViewModel.commentViewModel || thread.commentViewModel);
                  const e = vm && entities.get(vm.commentKey);
                  if (e) {
                    const p = e.properties || {};
                    const a = e.author || {};
                    const bar = e.toolbar || {};
                    comments.push({ id: p.commentId, url: p.commentId ? `${ORIGIN}/watch?v=${id}&lc=${p.commentId}` : undefined, author: a.displayName, authorUrl: a.channelId ? `${ORIGIN}/channel/${a.channelId}` : undefined, text: text(p.content), published: p.publishedTime, likes: bar.likeCountNotliked || bar.likeCountLiked || undefined, replies: bar.replyCount || undefined });
                  } else if (thread.comment && thread.comment.commentRenderer) {
                    const c = thread.comment.commentRenderer;
                    const nav = c.authorEndpoint && c.authorEndpoint.browseEndpoint;
                    comments.push({ id: c.commentId, url: `${ORIGIN}/watch?v=${id}&lc=${c.commentId}`, author: text(c.authorText), authorUrl: nav && nav.canonicalBaseUrl ? ORIGIN + nav.canonicalBaseUrl : undefined, text: text(c.contentText), published: text(c.publishedTimeText), likes: text(c.voteCount) || undefined, replies: c.replyCount || undefined });
                  }
                }
                const cont = item.continuationItemRenderer;
                if (cont) for (const c of walk(cont, "continuationCommand")) if (c && c.token) token = c.token;
              }
            }
            next = token;
          }
          return { videoId: id, comments, continuation: next || undefined };
        },
      };
      return api;
    },
    { summary: "YouTube search, video metadata, caption tracks, transcripts and comments" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
