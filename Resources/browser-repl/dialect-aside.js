// Aside dialect: the globals `aside repl` documents (`aside guide repl`),
// built on runtime-core. The snapshot text and diff follow
// docs/browser-repl/aside-snapshot-spec.md.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  const core = ns.core;
  const { Buffer } = core;

  // ---------------------------------------------------------------------------
  // POSIX path (subset of Node's path module)

  function normalizeParts(parts, allowAboveRoot) {
    const out = [];
    for (const p of parts) {
      if (!p || p === ".") continue;
      if (p === "..") {
        if (out.length && out[out.length - 1] !== "..") out.pop();
        else if (allowAboveRoot) out.push("..");
      } else out.push(p);
    }
    return out;
  }
  const path = {
    sep: "/",
    delimiter: ":",
    isAbsolute: (p) => String(p).startsWith("/"),
    normalize(p) {
      const abs = path.isAbsolute(p);
      const trailing = /\/$/.test(p);
      let s = normalizeParts(String(p).split("/"), !abs).join("/");
      if (!s && !abs) s = ".";
      if (s && trailing) s += "/";
      return (abs ? "/" : "") + s;
    },
    join(...parts) {
      const joined = parts.filter((p) => p !== "").join("/");
      return joined ? path.normalize(joined) : ".";
    },
    resolve(...parts) {
      let resolved = "";
      for (let i = parts.length - 1; i >= 0 && !path.isAbsolute(resolved); i--) {
        if (parts[i]) resolved = parts[i] + (resolved ? "/" + resolved : "");
      }
      if (!path.isAbsolute(resolved)) resolved = path._cwd() + "/" + resolved;
      return "/" + normalizeParts(resolved.split("/"), false).join("/");
    },
    dirname(p) {
      const s = String(p).replace(/\/+$/, "");
      const i = s.lastIndexOf("/");
      if (i < 0) return ".";
      return i === 0 ? "/" : s.slice(0, i);
    },
    basename(p, ext) {
      let b = String(p).replace(/\/+$/, "").split("/").pop();
      if (ext && b.endsWith(ext) && b !== ext) b = b.slice(0, -ext.length);
      return b;
    },
    extname(p) {
      const b = path.basename(p);
      const i = b.lastIndexOf(".");
      return i <= 0 ? "" : b.slice(i);
    },
    relative(from, to) {
      const a = path.resolve(from).split("/").filter(Boolean);
      const b = path.resolve(to).split("/").filter(Boolean);
      let i = 0;
      while (i < a.length && i < b.length && a[i] === b[i]) i++;
      return [...a.slice(i).map(() => ".."), ...b.slice(i)].join("/");
    },
    parse(p) {
      const base = path.basename(p);
      const ext = path.extname(p);
      return { root: path.isAbsolute(p) ? "/" : "", dir: path.dirname(p), base, ext, name: ext ? base.slice(0, -ext.length) : base };
    },
    format(o) {
      return (o.dir ? o.dir + "/" : o.root || "") + (o.base || (o.name || "") + (o.ext || ""));
    },
    _cwd: () => "/",
  };
  path.posix = path;

  // ---------------------------------------------------------------------------
  // Snapshot helpers

  const TRACKING_PARAMS = new Set(["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "gclid", "gclsrc",
    "fbclid", "mc_cid", "mc_eid", "msclkid", "twclid", "li_fat_id", "_ga", "_gl", "_t", "_ts", "_nc"]);

  // Aside's URL shortening, including its live-iterator skip (spec section 2).
  function truncateUrl(raw) {
    const cut = (s) => (s.length > 128 ? s.slice(0, 128) + "…" : s);
    let url;
    try {
      url = new core.URL(raw);
    } catch {
      return cut(String(raw));
    }
    const params = url.searchParams;
    for (const key of params.keys()) {
      if (TRACKING_PARAMS.has(key.toLowerCase())) params.delete(key);
    }
    return cut(url.toString());
  }

  // Myers diff with Aside's tie-breaks (spec section 11).
  function myers(a, b) {
    const N = a.length;
    const M = b.length;
    const MAX = N + M;
    if (MAX === 0) return [];
    if (N === M && a.every((x, i) => x === b[i])) return a.map((line) => ({ type: "equal", line }));
    const offset = MAX;
    const V = new Array(2 * MAX + 2).fill(-1);
    V[offset + 1] = 0;
    const trace = [];
    const at = (arr, k) => arr[offset + k];
    for (let d = 0; d <= MAX; d++) {
      trace.push(V.slice());
      for (let k = -d; k <= d; k += 2) {
        const down = k === -d || (k !== d && at(V, k - 1) < at(V, k + 1));
        let x = down ? at(V, k + 1) : at(V, k - 1) + 1;
        let y = x - k;
        while (x < N && y < M && a[x] === b[y]) {
          x++;
          y++;
        }
        V[offset + k] = x;
        if (x >= N && y >= M) return backtrack(trace, a, b, offset);
      }
    }
    return [];
  }
  function backtrack(trace, a, b, offset) {
    let x = a.length;
    let y = b.length;
    const out = [];
    const at = (arr, k) => arr[offset + k];
    for (let d = trace.length - 1; d >= 1; d--) {
      const V = trace[d];
      const k = x - y;
      const pk = k === -d || (k !== d && at(V, k - 1) < at(V, k + 1)) ? k + 1 : k - 1;
      const px = at(V, pk);
      const py = px - pk;
      while (x > px && y > py) {
        x--;
        y--;
        out.push({ type: "equal", line: a[x] });
      }
      if (x === px) {
        y--;
        out.push({ type: "insert", line: b[y] });
      } else {
        x--;
        out.push({ type: "delete", line: a[x] });
      }
    }
    while (x > 0 && y > 0) {
      x--;
      y--;
      out.push({ type: "equal", line: a[x] });
    }
    return out.reverse();
  }

  function diffText(previous, current) {
    const ops = myers(previous.trim().split("\n"), current.trim().split("\n"));
    const hunks = [];
    let o = 1;
    let n = 1;
    let hunk = null;
    for (const op of ops) {
      if (op.type === "equal") {
        hunk = null;
        o++;
        n++;
        continue;
      }
      if (!hunk) {
        hunk = { oldStart: o, newStart: n, oldCount: 0, newCount: 0, lines: [] };
        hunks.push(hunk);
      }
      if (op.type === "delete") {
        hunk.lines.push("-" + op.line);
        hunk.oldCount++;
        o++;
      } else {
        hunk.lines.push("+" + op.line);
        hunk.newCount++;
        n++;
      }
    }
    if (!hunks.length) return "No changes detected\n";
    const range = (start, count) => (count === 1 ? String(start) : `${start},${count}`);
    return hunks.map((h) => [`@@ -${range(h.oldStart, h.oldCount)} +${range(h.newStart, h.newCount)} @@`, ...h.lines].join("\n")).join("\n") + "\n";
  }

  // ---------------------------------------------------------------------------
  // Frame tree for a snapshot: prefixes in DOM order (cmux decision; Aside
  // uses frame registration order, which is unstable).

  async function frameTree(page) {
    await page._refreshFrames();
    const main = page.mainFrame();
    const info = new Map([[main, { prefix: "", depth: 0, parent: null, ownerRef: null }]]);
    const order = [main];
    let counter = 0;
    for (let i = 0; i < order.length; i++) {
      const frame = order[i];
      const children = [];
      let handles = [];
      try {
        handles = await frame._agent("iframeHandles");
      } catch {}
      for (const h of handles) {
        const child = await frame._contentFrame(h).catch(() => null);
        if (child && !info.has(child) && !children.includes(child)) {
          child._ownerHandle = h;
          children.push(child);
        }
      }
      for (const child of frame.childFrames()) if (!children.includes(child) && !info.has(child)) children.push(child);
      for (const child of children) {
        info.set(child, { prefix: `f${++counter}`, depth: info.get(frame).depth + 1, parent: frame });
        order.push(child);
      }
    }
    return { order, info };
  }

  function stitch(texts, info, rootFrame, ownerRefs) {
    const byDepth = [...texts.keys()].filter((f) => f !== rootFrame).sort((a, b) => info.get(b).depth - info.get(a).depth);
    for (const frame of byDepth) {
      const parent = info.get(frame).parent;
      if (!texts.has(parent)) continue;
      const child = texts.get(frame);
      let parentText = texts.get(parent);
      const ref = ownerRefs.get(frame);
      const childLines = child ? child.split("\n") : [];
      let placed = false;
      if (ref) {
        const lines = parentText.split("\n");
        const re = new RegExp(`^(\\s*)- iframe(.*? )?\\[ref=${ref}\\]`);
        const index = lines.findIndex((l) => re.test(l));
        if (index >= 0) {
          const indent = re.exec(lines[index])[1] + "  ";
          if (child) lines[index] += ":";
          lines.splice(index + 1, 0, ...childLines.map((l) => indent + l));
          parentText = lines.join("\n");
          placed = true;
        }
      }
      if (!placed) {
        const orphan = [`- iframe${child ? ":" : ""}`, ...childLines.map((l) => "  " + l)].join("\n");
        parentText = parentText ? parentText + "\n" + orphan : orphan;
      }
      texts.set(parent, parentText);
    }
    return texts.get(rootFrame) || "";
  }

  // ---------------------------------------------------------------------------
  // Console formatting (close to Node's util.inspect for common values)

  function inspect(value, depth = 0, seen = new Set()) {
    if (typeof value === "string") return depth ? JSON.stringify(value).replace(/^"|"$/g, "'") : value;
    if (value === null || value === undefined || typeof value === "number" || typeof value === "boolean") return String(value);
    if (typeof value === "bigint") return value + "n";
    if (typeof value === "symbol") return value.toString();
    if (typeof value === "function") return `[Function: ${value.name || "(anonymous)"}]`;
    if (value instanceof Error) return value.stack || `${value.name}: ${value.message}`;
    if (seen.has(value)) return "[Circular]";
    if (depth > 4) return Array.isArray(value) ? "[Array]" : "[Object]";
    seen.add(value);
    try {
      if (Buffer.isBuffer(value)) return `<Buffer ${Array.from(value.subarray(0, 50), (b) => b.toString(16).padStart(2, "0")).join(" ")}${value.length > 50 ? " ..." : ""}>`;
      if (Array.isArray(value)) return `[ ${value.map((v) => inspect(v, depth + 1, seen)).join(", ")} ]`.replace("[  ]", "[]");
      if (value instanceof Map) return `Map(${value.size}) { ${[...value].map(([k, v]) => `${inspect(k, depth + 1, seen)} => ${inspect(v, depth + 1, seen)}`).join(", ")} }`;
      if (value instanceof Set) return `Set(${value.size}) { ${[...value].map((v) => inspect(v, depth + 1, seen)).join(", ")} }`;
      if (value instanceof core.Page) return `Page(${value.url()})`;
      if (value instanceof core.Locator) return value.toString();
      const keys = Object.keys(value);
      if (!keys.length) return "{}";
      return `{ ${keys.map((k) => `${/^[A-Za-z_$][\w$]*$/.test(k) ? k : JSON.stringify(k)}: ${inspect(value[k], depth + 1, seen)}`).join(", ")} }`;
    } finally {
      seen.delete(value);
    }
  }
  const formatArgs = (args) => args.map((a) => inspect(a)).join(" ");

  // ---------------------------------------------------------------------------

  function createAsideGlobals(session, options = {}) {
    const host = session.host;
    const workDir = options.workDir || host.workDir || "/";
    const out = (line) => host.console.log(line);
    const state = { page: undefined, tabs: [] };
    const downloadPaths = new Set();
    session.onDownloadPath = (p) => downloadPaths.add(host.fs && host.fs.realpath ? host.fs.realpath(p) : p);
    path._cwd = () => workDir;

    // fs confined to the session work dir. Completed downloads stay readable.
    function resolvePath(p, forWrite) {
      if (p && typeof p === "object" && p.href) p = decodeURIComponent(String(p.pathname));
      const abs = path.resolve(workDir, String(p));
      const real = host.fs && host.fs.realpath ? host.fs.realpath(abs) : abs;
      const inside = (x) => x === workDir || x.startsWith(workDir.replace(/\/$/, "") + "/");
      if (inside(abs) && inside(real)) return abs;
      if (!forWrite && (downloadPaths.has(real) || downloadPaths.has(abs))) return abs;
      const e = new Error(`EACCES: permission denied, '${p}' is outside the REPL working directory`);
      e.code = "EACCES";
      throw e;
    }
    const toBytes = (data, encoding) => {
      if (typeof data === "string") return Buffer.from(data, typeof encoding === "string" ? encoding : encoding && encoding.encoding);
      if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) return Buffer.from(data);
      return Buffer.from(String(data));
    };
    const encodingOf = (o) => (typeof o === "string" ? o : o && o.encoding) || null;
    const fs = {
      async readFile(p, opts) {
        const bytes = Buffer.from(await host.fs.readFile(resolvePath(p, false)), "base64");
        const enc = encodingOf(opts);
        return enc ? bytes.toString(enc) : bytes;
      },
      async writeFile(p, data, opts) {
        await host.fs.writeFile(resolvePath(p, true), toBytes(data, opts).toString("base64"));
      },
      async appendFile(p, data, opts) {
        await host.fs.appendFile(resolvePath(p, true), toBytes(data, opts).toString("base64"));
      },
      async mkdir(p, opts) {
        await host.fs.mkdir(resolvePath(p, true), !!(opts && opts.recursive));
      },
      async readdir(p) {
        return host.fs.readdir(resolvePath(p, false));
      },
      async stat(p) {
        const s = await host.fs.stat(resolvePath(p, false));
        return { size: s.size, mtimeMs: s.mtimeMs, isFile: () => s.isFile, isDirectory: () => s.isDirectory };
      },
      async rm(p, opts) {
        await host.fs.rm(resolvePath(p, true), !!(opts && opts.recursive));
      },
      async unlink(p) {
        await host.fs.rm(resolvePath(p, true), false);
      },
      async access(p) {
        if (!(await host.fs.exists(resolvePath(p, false)))) {
          const e = new Error(`ENOENT: no such file or directory, access '${p}'`);
          e.code = "ENOENT";
          throw e;
        }
      },
      async exists(p) {
        return host.fs.exists(resolvePath(p, false));
      },
    };
    fs.promises = fs;
    session.files = {
      read: async (p) => Buffer.from(await host.fs.readFile(resolvePath(p, false)), "base64"),
      readAbsolute: async (p) => Buffer.from(await host.fs.readFile(p), "base64"),
      write: (p, bytes) => host.fs.writeFile(resolvePath(p, true), Buffer.from(bytes).toString("base64")),
    };

    const describe = (page) => `${page._title || ""} (${page.url()})`;
    const indexOf = (page) => state.tabs.indexOf(page);
    async function setActive(page, verb) {
      state.page = page;
      if (!state.tabs.includes(page)) state.tabs.push(page);
      await page._syncInfo().catch(() => {});
      out(`✔︎ ${verb}: tabs[${indexOf(page)}], page → ${describe(page)}`);
      return page;
    }

    async function openTab(url) {
      const page = await session.newPage(url);
      if (url) await page.waitForLoadState("domcontentloaded").catch(() => {});
      return setActive(page, "Opened a new tab and set it active");
    }
    async function closeTab(tab) {
      const page = tab || state.page;
      if (!page) throw new Error("closeTab: no tab to close");
      await page.close();
      state.tabs = state.tabs.filter((t) => t !== page);
      if (state.page === page) state.page = state.tabs[state.tabs.length - 1];
      out(`✔︎ Closed tab${state.page ? `; page → ${describe(state.page)}` : ""}`);
    }
    async function listBrowserTabs() {
      const list = await session.call("tabs.list", {});
      return list.map((t) => ({
        active: !!t.active,
        faviconUrl: t.faviconUrl || "",
        focusedWindow: !!t.active,
        id: `tab:${t.targetId}`,
        targetId: t.targetId,
        title: t.title,
        url: t.url,
        windowId: t.windowId,
      }));
    }
    async function attachBrowserTab(targetId) {
      const list = await session.call("tabs.list", {});
      if (!list.some((t) => t.targetId === targetId)) throw new Error(`No open browser tab with targetId ${targetId}`);
      return setActive(session.pageFor(targetId), "Attached tab and set it active");
    }
    async function attachActiveBrowserTab() {
      const list = await session.call("tabs.list", {});
      const active = list.find((t) => t.active) || list[0];
      if (!active) throw new Error("No open browser tab");
      return attachBrowserTab(active.targetId);
    }
    function getTabByTargetId(targetId) {
      return state.tabs.find((t) => t._targetId === targetId);
    }

    const queues = new WeakMap();
    function snapshot(page, opts) {
      if (!page || !(page instanceof core.Page)) return Promise.reject(new Error("snapshot(page, options?): page must be a Page"));
      const prev = queues.get(page) || Promise.resolve();
      const run = prev.catch(() => {}).then(() => takeSnapshot(page, opts || {}));
      queues.set(page, run);
      return run;
    }

    async function takeSnapshot(page, rawOptions, { updateDiff = true } = {}) {
      const options = {};
      for (const [k, v] of Object.entries(rawOptions)) if (v !== undefined) options[k] = v;
      if (options.selector) {
        const found = await page.mainFrame().evaluate((sel) => !!document.querySelector(sel), options.selector);
        if (!found) throw new Error(`Selector "${options.selector}" matched no elements on page.`);
      }
      const { order, info } = await frameTree(page);
      page._refPrefixes = new Map(order.map((f) => [info.get(f).prefix, f]));
      let rootFrame = page.mainFrame();
      if (options.ref) {
        const prefix = (/^(f\d+)?e\d+$/.exec(options.ref) || [])[1] || "";
        rootFrame = page._refPrefixes.get(prefix);
        if (!rootFrame) throw new Error(`Ref "${options.ref}" points to a frame that is no longer available. Take a new snapshot.`);
      }
      const inSubtree = (f) => {
        for (let cur = f; cur; cur = info.get(cur) && info.get(cur).parent) if (cur === rootFrame) return true;
        return false;
      };
      const frames = order.filter(inSubtree);
      const base = { interactive: options.interactive, showHidden: options.showHidden, maxDepth: options.maxDepth, maxChars: options.maxChars };
      for (const k of Object.keys(base)) if (base[k] === undefined) delete base[k];
      const results = await Promise.all(frames.map(async (frame) => {
        const isRoot = frame === rootFrame;
        const opts = { ...base, refPrefix: info.get(frame).prefix };
        if (isRoot && options.ref) opts.ref = options.ref;
        if (isRoot && options.selector) opts.selector = options.selector;
        const attempts = isRoot ? 3 : 1;
        let lastError;
        for (let i = 0; i < attempts; i++) {
          if (i) await session.sleep(300);
          try {
            return await frame._agent("snapshot", opts);
          } catch (e) {
            lastError = e;
          }
        }
        if (isRoot) throw lastError;
        return null;
      }));
      const texts = new Map();
      const refs = {};
      const ownerRefs = new Map();
      for (let i = 0; i < frames.length; i++) {
        const r = results[i];
        if (!r) continue;
        if (r.error) {
          if (frames[i] === rootFrame) throw new Error(r.error);
          continue;
        }
        texts.set(frames[i], r.text);
        Object.assign(refs, r.refs);
        for (const { ref, handle } of r.iframes) {
          const child = await frames[i]._contentFrame(handle).catch(() => null);
          if (child) ownerRefs.set(child, ref);
        }
      }
      const raw = stitch(texts, info, rootFrame, ownerRefs);
      await page._syncInfo().catch(() => {});
      const lines = [];
      if (options.interactive) lines.push("# note: interactive (clickable / focusable) elements only.");
      if (options.showHidden) lines.push("# note: hidden elements are shown.");
      lines.push(`- title: "${page._title || ""}" [url=${truncateUrl(page.url())}]`);
      if (raw) lines.push(raw);
      const tree = lines.filter(Boolean).join("\n");
      const previous = page._asidePreviousSnapshot || "";
      if (updateDiff) page._asidePreviousSnapshot = raw;
      const d = diffText(previous, raw);
      page._asideLastRefs = Object.keys(refs);
      return { tree, refs, diff: d.length > tree.length ? tree : d };
    }

    async function annotatedScreenshot(page) {
      if (!page || !(page instanceof core.Page)) throw new Error("annotatedScreenshot(page): page must be a Page");
      if (!page._asideLastRefs) await takeSnapshot(page, { interactive: true }, { updateDiff: false });
      const frames = [...page._refPrefixes.entries()];
      const byPrefix = new Map(frames.map(([prefix]) => [prefix, []]));
      for (const ref of page._asideLastRefs) {
        const prefix = (/^(f\d+)?e\d+$/.exec(ref) || [])[1] || "";
        if (byPrefix.has(prefix)) byPrefix.get(prefix).push(ref);
      }
      const drawn = [];
      try {
        for (const [prefix, frame] of frames) {
          const list = byPrefix.get(prefix);
          if (!list.length) continue;
          await frame._agent("annotate", list);
          drawn.push(frame);
        }
        const png = await page.screenshot();
        return { base64Image: png.toString("base64") };
      } finally {
        for (const frame of drawn) await frame._agent("clearAnnotations").catch(() => {});
      }
    }

    // Cookie-bearing fetch through the host; cookies come from the browser.
    async function fetchWithCookies(input, init = {}) {
      const base = state.page ? state.page.url() : undefined;
      const url = new core.URL(String(input && input.url ? input.url : input), base || undefined).href;
      const headers = {};
      const src = init.headers || {};
      if (typeof src.forEach === "function" && !Array.isArray(src)) src.forEach((v, k) => (headers[k] = v));
      else if (Array.isArray(src)) for (const [k, v] of src) headers[k] = v;
      else Object.assign(headers, src);
      if (!host.fetchHandlesCookies && !Object.keys(headers).some((k) => k.toLowerCase() === "cookie") && init.credentials !== "omit") {
        const cookies = await session.call("cookies.get", { urls: [url] }).catch(() => []);
        if (cookies.length) headers.cookie = cookies.map((c) => `${c.name}=${c.value}`).join("; ");
      }
      const body = init.body === undefined || init.body === null ? undefined : Buffer.from(init.body).toString("base64");
      const r = await host.fetch(url, { method: init.method || "GET", headers, body, targetId: state.page && state.page._targetId });
      const bytes = Buffer.from(r.base64 || "", "base64");
      const lower = {};
      for (const [k, v] of Object.entries(r.headers || {})) lower[k.toLowerCase()] = v;
      return {
        ok: r.status >= 200 && r.status < 300,
        status: r.status,
        statusText: r.statusText || "",
        url: r.url || url,
        redirected: !!r.redirected,
        headers: {
          get: (k) => (lower[String(k).toLowerCase()] !== undefined ? lower[String(k).toLowerCase()] : null),
          has: (k) => lower[String(k).toLowerCase()] !== undefined,
          forEach: (fn) => Object.entries(lower).forEach(([k, v]) => fn(v, k)),
          entries: () => Object.entries(lower)[Symbol.iterator](),
        },
        text: async () => bytes.toString("utf8"),
        json: async () => JSON.parse(bytes.toString("utf8")),
        arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
        bytes: async () => new Uint8Array(bytes),
      };
    }

    const consoleApi = {
      log: (...a) => out(formatArgs(a)),
      info: (...a) => out(formatArgs(a)),
      debug: (...a) => out(formatArgs(a)),
      warn: (...a) => out(formatArgs(a)),
      error: (...a) => out(formatArgs(a)),
      dir: (v) => out(inspect(v)),
      table: (v) => out(inspect(v)),
    };

    const globals = {
      listBrowserTabs,
      attachBrowserTab,
      attachActiveBrowserTab,
      getTabByTargetId,
      openTab,
      closeTab,
      snapshot,
      annotatedScreenshot,
      fetch: fetchWithCookies,
      fs,
      path,
      Buffer,
      sleep: (ms) => session.sleep(ms),
      display: (value) => (host.display ? host.display(value) : out(inspect(value))),
      pwd: () => workDir,
      console: consoleApi,
    };
    Object.defineProperty(globals, "page", { get: () => state.page, set: (v) => (state.page = v), enumerable: true });
    Object.defineProperty(globals, "tabs", { get: () => state.tabs, enumerable: true });

    // Pages the page opens are not attached automatically; Aside attaches
    // tabs only through openTab/attachBrowserTab.
    session.normalizeSelector = (selector) => selector;
    return globals;
  }

  // Aside addresses snapshot refs as bare selectors ("e5", "f1e2", "[ref=e5]").
  const REF_SELECTOR = /^(?:\[ref=)?((f\d+)?e\d+)\]?$/;
  core.Page.prototype._normalizeSelector = function (selector) {
    const m = typeof selector === "string" ? REF_SELECTOR.exec(selector.trim()) : null;
    if (m && (selector.trim().startsWith("[ref=") ? selector.trim().endsWith("]") : !selector.includes("]"))) return `aria-ref=${m[1]}`;
    return selector;
  };
  const frameLocator = core.Frame.prototype.locator;
  core.Frame.prototype.locator = function (selector, options) {
    if (this !== this._page._mainFrame && typeof selector === "string" && REF_SELECTOR.test(selector.trim())) {
      throw new Error("Snapshot refs already include frame identity; use page.locator(ref) instead of frame.locator(ref).");
    }
    return frameLocator.call(this, selector, options);
  };

  ns.aside = { createAsideGlobals, truncateUrl, myers, diffText, path, inspect, formatArgs };
})(typeof globalThis !== "undefined" ? globalThis : this);
