// cmux browser REPL globals (docs/browser-repl/README.md, Globals): page,
// tabs, snapshot, screenshot, fetch, fs/path/os/Buffer, sleep, display,
// session, console. Built on runtime-core (Playwright model) and snapshot.js.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  const core = ns.core;
  const { Buffer } = core;

  // ---------------------------------------------------------------------------
  // node:path (POSIX)

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
  function createPath(cwd) {
    const path = {
      sep: "/",
      delimiter: ":",
      isAbsolute: (p) => String(p).startsWith("/"),
      normalize(p) {
        p = String(p);
        const abs = path.isAbsolute(p);
        const trailing = /\/$/.test(p);
        let s = normalizeParts(p.split("/"), !abs).join("/");
        if (!s && !abs) s = ".";
        if (s && trailing) s += "/";
        return (abs ? "/" : "") + s;
      },
      join(...parts) {
        const joined = parts.map(String).filter((p) => p !== "").join("/");
        return joined ? path.normalize(joined) : ".";
      },
      resolve(...parts) {
        let resolved = "";
        for (let i = parts.length - 1; i >= 0 && !path.isAbsolute(resolved); i--) {
          const part = String(parts[i]);
          if (part) resolved = part + (resolved ? "/" + resolved : "");
        }
        if (!path.isAbsolute(resolved)) resolved = cwd() + "/" + resolved;
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
    };
    path.posix = path;
    return path;
  }

  // ---------------------------------------------------------------------------
  // node:fs on the host's synchronous fs operations. The host confines paths
  // to the session directory and the temporary directory.

  function createFs(host, path) {
    const op = (name, args) => host.fsOp(name, args);
    const toPath = (p) => (p && typeof p === "object" && p.href ? decodeURIComponent(String(p.pathname)) : String(p));
    const abs = (p) => path.resolve(toPath(p));
    const encodingOf = (o) => (typeof o === "string" ? o : o && o.encoding) || null;
    const bytesOf = (data, o) => {
      if (typeof data === "string") return Buffer.from(data, encodingOf(o) || "utf8");
      if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) return Buffer.from(data);
      return Buffer.from(String(data));
    };
    const statOf = (s) => ({
      size: s.size,
      mtimeMs: s.mtimeMs,
      birthtimeMs: s.birthtimeMs,
      mtime: new Date(s.mtimeMs),
      birthtime: new Date(s.birthtimeMs || s.mtimeMs),
      isFile: () => s.type === "file",
      isDirectory: () => s.type === "directory",
      isSymbolicLink: () => s.type === "symlink",
    });
    const sync = {
      readFileSync(p, o) {
        const bytes = Buffer.from(op("readFile", { path: abs(p) }), "base64");
        const enc = encodingOf(o);
        return enc ? bytes.toString(enc) : bytes;
      },
      writeFileSync: (p, data, o) => void op("writeFile", { path: abs(p), base64: bytesOf(data, o).toString("base64") }),
      appendFileSync: (p, data, o) => void op("writeFile", { path: abs(p), base64: bytesOf(data, o).toString("base64"), append: true }),
      mkdirSync(p, o) {
        const target = abs(p);
        const recursive = !!(o && o.recursive);
        const existed = recursive && op("exists", { path: target });
        op("mkdir", { path: target, recursive });
        return recursive && !existed ? target : undefined;
      },
      readdirSync(p, o) {
        const entries = op("readdir", { path: abs(p) });
        if (o && o.withFileTypes) {
          return entries.map((e) => ({
            name: e.name,
            isFile: () => e.type === "file",
            isDirectory: () => e.type === "directory",
            isSymbolicLink: () => e.type === "symlink",
          }));
        }
        return entries.map((e) => e.name);
      },
      statSync: (p) => statOf(op("stat", { path: abs(p) })),
      lstatSync: (p) => statOf(op("stat", { path: abs(p) })),
      existsSync(p) {
        try {
          return !!op("exists", { path: abs(p) });
        } catch {
          return false;
        }
      },
      accessSync(p) {
        if (!sync.existsSync(p)) {
          const e = new Error(`ENOENT: no such file or directory, access '${toPath(p)}'`);
          e.code = "ENOENT";
          throw e;
        }
      },
      rmSync: (p, o) => void op("rm", { path: abs(p), recursive: !!(o && o.recursive), force: !!(o && o.force) }),
      rmdirSync: (p, o) => void op("rm", { path: abs(p), recursive: !!(o && o.recursive) }),
      unlinkSync: (p) => void op("rm", { path: abs(p) }),
      renameSync: (from, to) => void op("rename", { from: abs(from), to: abs(to) }),
      copyFileSync: (from, to) => void op("copyFile", { from: abs(from), to: abs(to) }),
      realpathSync: (p) => op("resolve", { path: abs(p) }),
      mkdtempSync(prefix) {
        const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
        for (let attempt = 0; attempt < 16; attempt++) {
          let suffix = "";
          for (let i = 0; i < 6; i++) suffix += chars[Math.floor(Math.random() * chars.length)];
          const dir = abs(String(prefix) + suffix);
          if (op("exists", { path: dir })) continue;
          op("mkdir", { path: dir });
          return dir;
        }
        const e = new Error(`EEXIST: file already exists, mkdtemp '${prefix}XXXXXX'`);
        e.code = "EEXIST";
        throw e;
      },
    };
    const promises = {};
    const fs = { promises };
    for (const [key, fn] of Object.entries(sync)) {
      fs[key] = fn;
      if (key === "existsSync") continue;
      const name = key.replace(/Sync$/, "");
      promises[name] = async (...args) => fn(...args);
      // Node's callback form; without a callback it returns a promise.
      fs[name] = (...args) => {
        const cb = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const p = promises[name](...args);
        if (!cb) return p;
        p.then((v) => cb(null, v), (e) => cb(e));
        return undefined;
      };
    }
    fs.exists = (p, cb) => {
      const v = sync.existsSync(p);
      if (typeof cb === "function") cb(v);
      return Promise.resolve(v);
    };
    fs.constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 };
    return fs;
  }

  function createOs(host) {
    return {
      tmpdir: () => host.tmpdir,
      homedir: () => host.homedir,
      platform: () => "darwin",
      type: () => "Darwin",
      arch: () => "arm64",
      EOL: "\n",
    };
  }

  // ---------------------------------------------------------------------------
  // Printing (close to Node's util.inspect for common values)

  function imageSize(bytes) {
    if (bytes.length > 24 && bytes[0] === 0x89 && bytes[1] === 0x50) {
      const u32 = (i) => ((bytes[i] << 24) | (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3]) >>> 0;
      return { type: "png", width: u32(16), height: u32(20) };
    }
    if (bytes[0] === 0xff && bytes[1] === 0xd8) {
      for (let i = 2; i + 9 < bytes.length;) {
        if (bytes[i] !== 0xff) break;
        const marker = bytes[i + 1];
        const len = (bytes[i + 2] << 8) | bytes[i + 3];
        if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
          return { type: "jpeg", height: (bytes[i + 5] << 8) | bytes[i + 6], width: (bytes[i + 7] << 8) | bytes[i + 8] };
        }
        i += 2 + len;
      }
      return { type: "jpeg", width: 0, height: 0 };
    }
    return { type: "png", width: 0, height: 0 };
  }

  // An image that shows itself when printed: the bytes go to a file in the
  // temporary directory and the path is printed, so an agent can open it.
  class Image {
    constructor(bytes) {
      this.buffer = Buffer.from(bytes);
      const size = imageSize(this.buffer);
      this.type = size.type;
      this.width = size.width;
      this.height = size.height;
    }
    get base64() {
      return this.buffer.toString("base64");
    }
    toString() {
      return `Image ${this.width}x${this.height} ${this.type}`;
    }
  }

  function inspect(value, depth = 0, seen = new Set()) {
    const nested = depth > 0;
    if (typeof value === "string") return nested ? `'${value.replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/\n/g, "\\n")}'` : value;
    if (value === null || value === undefined || typeof value === "number" || typeof value === "boolean") return String(value);
    if (typeof value === "bigint") return value + "n";
    if (typeof value === "symbol") return value.toString();
    if (typeof value === "function") return value.prototype && /^class\b/.test(Function.prototype.toString.call(value)) ? `[class ${value.name}]` : `[Function: ${value.name || "(anonymous)"}]`;
    if (value instanceof Error) return nested ? `[${value.name}: ${value.message}]` : value.stack && value.stack.includes(value.message) ? value.stack : `${value.name}: ${value.message}`;
    if (value instanceof ns.snapshot.Snapshot) return nested ? "[Snapshot]" : String(value);
    if (value instanceof Image) return `[${value}]`;
    if (value instanceof core.Page) return `Page { id: '${value.id}', url: '${value.url()}' }`;
    if (value instanceof core.Locator) return value.toString();
    if (value instanceof core.ConsoleMessage) return `ConsoleMessage { type: '${value.type()}', text: ${inspect(value.text(), 1)} }`;
    if (value instanceof Date) return isNaN(value) ? "Invalid Date" : value.toISOString();
    if (Object.prototype.toString.call(value) === "[object RegExp]") return String(value);
    if (typeof value.then === "function") return "Promise { <pending> }";
    if (seen.has(value)) return "[Circular]";
    if (depth > 3) return Array.isArray(value) ? "[Array]" : "[Object]";
    seen.add(value);
    try {
      const wrap = (open, items, close) => {
        if (!items.length) return open + close;
        const single = `${open} ${items.join(", ")} ${close}`;
        if (single.length <= 72 && !single.includes("\n")) return single;
        const pad = "  ".repeat(depth + 1);
        return `${open}\n${items.map((i) => pad + i).join(",\n")}\n${"  ".repeat(depth)}${close}`;
      };
      if (Buffer.isBuffer(value)) {
        const hex = Array.from(value.subarray(0, 50), (b) => b.toString(16).padStart(2, "0")).join(" ");
        return `<Buffer ${hex}${value.length > 50 ? ` ... ${value.length - 50} more bytes` : ""}>`;
      }
      if (ArrayBuffer.isView(value)) {
        const items = Array.from(value.subarray(0, 100), String);
        if (value.length > 100) items.push(`... ${value.length - 100} more items`);
        return `${value.constructor.name}(${value.length}) ${wrap("[", items, "]")}`;
      }
      if (Array.isArray(value)) {
        const items = value.slice(0, 100).map((v) => inspect(v, depth + 1, seen));
        if (value.length > 100) items.push(`... ${value.length - 100} more items`);
        return wrap("[", items, "]");
      }
      if (value instanceof Map) {
        return `Map(${value.size}) ${wrap("{", [...value].map(([k, v]) => `${inspect(k, depth + 1, seen)} => ${inspect(v, depth + 1, seen)}`), "}")}`;
      }
      if (value instanceof Set) return `Set(${value.size}) ${wrap("{", [...value].map((v) => inspect(v, depth + 1, seen)), "}")}`;
      const keys = Object.keys(value);
      const items = keys.map((k) => `${/^[A-Za-z_$][\w$]*$/.test(k) ? k : `'${k}'`}: ${inspect(value[k], depth + 1, seen)}`);
      const ctor = value.constructor && value.constructor !== Object && value.constructor.name ? value.constructor.name + " " : "";
      return ctor + wrap("{", items, "}");
    } finally {
      seen.delete(value);
    }
  }

  // ---------------------------------------------------------------------------

  function createGlobals(session, host) {
    const workDir = () => host.workDir || "/";
    const path = createPath(workDir);
    const fs = createFs(host, path);
    const os = createOs(host);
    const out = (level, text) => host.print(level, text);
    const state = { current: null, name: null, images: 0 };

    session.files = {
      read: async (p) => fs.readFileSync(p),
      readAbsolute: async (p) => fs.readFileSync(p),
      write: async (p, bytes) => fs.writeFileSync(p, bytes),
    };

    const modules = {
      fs,
      "fs/promises": fs.promises,
      path,
      os,
      buffer: { Buffer },
    };
    function importModule(specifier) {
      const name = String(specifier).replace(/^node:/, "");
      const mod = modules[name];
      if (!mod) throw new Error(`Cannot import ${specifier}: the cmux browser REPL provides node:fs, node:fs/promises, node:path, node:os and node:buffer`);
      return Object.assign({ default: mod }, mod);
    }

    function currentPage() {
      if (!state.current || state.current.isClosed()) state.current = session.lazyPage();
      return state.current;
    }

    function imageLine(image) {
      const dir = path.join(host.tmpdir, "cmux-browser-repl", String(host.sessionId || "session").replace(/[^\w.-]/g, "_"));
      fs.mkdirSync(dir, { recursive: true });
      const file = path.join(dir, `image-${++state.images}.${image.type === "jpeg" ? "jpg" : "png"}`);
      fs.writeFileSync(file, image.buffer);
      return `[${image}: ${file}]`;
    }

    // Shows a value the way the REPL prints its last expression.
    function show(value) {
      if (value === undefined) return;
      if (value instanceof Image) out("log", imageLine(value));
      else out("log", inspect(value));
    }

    const consoleApi = {};
    for (const [method, level] of [["log", "log"], ["info", "info"], ["debug", "debug"], ["warn", "warn"], ["error", "error"], ["trace", "log"]]) {
      consoleApi[method] = (...args) => {
        out(level, args.map((a) => inspect(a)).join(" "));
      };
    }
    consoleApi.dir = (v) => {
      out("log", inspect(v));
    };
    consoleApi.table = consoleApi.dir;

    function splitTarget(target, options) {
      if (target && typeof target === "object" && !(target instanceof core.Page) && !(target instanceof core.Locator)) return [undefined, target];
      return [target, options || {}];
    }
    const pageOf = (target) => (target instanceof core.Page ? target : target instanceof core.Locator ? target._page : currentPage());

    async function snapshot(target, options) {
      [target, options] = splitTarget(target, options);
      const page = pageOf(target);
      return ns.snapshot.takeSnapshot(page, target instanceof core.Page ? undefined : target, options);
    }

    async function screenshot(target, options) {
      [target, options] = splitTarget(target, options);
      const page = pageOf(target);
      const scoped = typeof target === "string" ? page.ref(target) : target instanceof core.Locator ? target : null;
      const clear = options.annotate ? await ns.snapshot.annotate(page, scoped || undefined) : null;
      let bytes;
      try {
        const shot = { type: options.type, quality: options.quality, fullPage: options.fullPage, clip: options.clip };
        bytes = scoped ? await scoped.screenshot(shot) : await page.screenshot(shot);
      } finally {
        if (clear) await clear();
      }
      if (options.path) fs.writeFileSync(options.path, bytes);
      return new Image(bytes);
    }

    class Headers {
      constructor(init) {
        this._map = new Map();
        for (const [k, v] of Object.entries(init || {})) this._map.set(k.toLowerCase(), String(v));
      }
      get(k) {
        const v = this._map.get(String(k).toLowerCase());
        return v === undefined ? null : v;
      }
      has(k) {
        return this._map.has(String(k).toLowerCase());
      }
      forEach(fn) {
        for (const [k, v] of this._map) fn(v, k, this);
      }
      entries() {
        return this._map.entries();
      }
      keys() {
        return this._map.keys();
      }
      [Symbol.iterator]() {
        return this._map.entries();
      }
    }

    // Standard fetch that sends, and stores, the current tab's cookies.
    async function fetchWithCookies(input, init = {}) {
      const page = state.current && !state.current.isClosed() ? state.current : null;
      const base = page && /^https?:/.test(page.url()) ? page.url() : undefined;
      const url = new core.URL(String(input && input.url ? input.url : input), base).href;
      const headers = {};
      const src = init.headers || {};
      if (typeof src.forEach === "function" && !Array.isArray(src)) src.forEach((v, k) => (headers[k] = v));
      else if (Array.isArray(src)) for (const [k, v] of src) headers[k] = v;
      else Object.assign(headers, src);
      if (!host.fetchHandlesCookies && init.credentials !== "omit" && !Object.keys(headers).some((k) => k.toLowerCase() === "cookie")) {
        const cookies = await session.call("cookies.get", { urls: [url] }).catch(() => []);
        if (cookies.length) headers.cookie = cookies.map((c) => `${c.name}=${c.value}`).join("; ");
      }
      const body = init.body === undefined || init.body === null ? undefined : Buffer.from(init.body).toString("base64");
      const targetId = page && !String(page._targetId).startsWith("lazy:") ? page._targetId : undefined;
      const r = await host.fetch(url, { method: (init.method || "GET").toUpperCase(), headers, body, targetId });
      const bytes = Buffer.from(r.base64 || "", "base64");
      return {
        ok: r.status >= 200 && r.status < 300,
        status: r.status,
        statusText: r.statusText || "",
        url: r.url || url,
        redirected: !!r.redirected,
        headers: new Headers(r.headers),
        text: async () => bytes.toString("utf8"),
        json: async () => JSON.parse(bytes.toString("utf8")),
        arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
        bytes: async () => new Uint8Array(bytes),
      };
    }

    async function pageById(id) {
      if (id instanceof core.Page) return id;
      const list = await session.call("tabs.list", {});
      if (!list.some((t) => t.targetId === String(id))) throw new Error(`No open tab with id ${JSON.stringify(String(id))}; see tabs.list()`);
      const page = session.pageFor(String(id));
      await page._syncInfo().catch(() => {});
      return page;
    }

    const tabs = {
      async list() {
        const list = await session.call("tabs.list", {});
        const current = state.current && state.current._targetId;
        return list.map((t) => ({ id: t.targetId, title: t.title, url: t.url, active: !!t.active, current: t.targetId === current }));
      },
      async open(url, options = {}) {
        const page = await session.newPage(url, { background: !!options.background });
        if (url) await page.waitForLoadState("load").catch(() => {});
        await page._syncInfo().catch(() => {});
        if (!options.background) state.current = page;
        return page;
      },
      current: () => currentPage(),
      async use(tabOrId) {
        state.current = await pageById(tabOrId);
        return state.current;
      },
      get: (id) => pageById(id),
    };

    const sessionApi = {
      get id() {
        return host.sessionId || null;
      },
      async name(label) {
        state.name = String(label);
        try {
          await session.call("session.name", { name: state.name });
        } catch (e) {
          if (e && e.code !== "unsupported") throw e;
        }
        return state.name;
      },
      keep: (page) => (page || currentPage()).keep(),
      guide: () => (host.readResource ? host.readResource("guide.md") : null),
    };

    const globals = {
      tabs,
      snapshot,
      screenshot,
      fetch: fetchWithCookies,
      fs,
      path,
      os,
      Buffer,
      require: (name) => importModule(name).default,
      sleep: (ms) => session.sleep(ms),
      display: (value) => {
        show(value);
      },
      session: sessionApi,
      console: consoleApi,
      URL: core.URL,
      URLSearchParams: core.URLSearchParams,
    };
    Object.defineProperty(globals, "page", {
      get: () => currentPage(),
      set: (v) => {
        state.current = v;
      },
      enumerable: true,
      configurable: true,
    });
    return { globals, show, importModule, state };
  }

  ns.api = { createGlobals, createPath, createFs, inspect, Image, imageSize };
})(typeof globalThis !== "undefined" ? globalThis : this);
