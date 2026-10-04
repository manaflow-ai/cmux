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
      lstatSync: (p) => statOf(op("lstat", { path: abs(p) })),
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
  // Content export (page.exportContent, tabs.content)

  // Runs in the page: its visible content as Markdown.
  function pageMarkdown() {
    const skip = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS", "IFRAME"]);
    const clean = (t) => t.replace(/\s+/g, " ");
    const hidden = (el) => { const cs = getComputedStyle(el); return cs.display === "none" || cs.visibility === "hidden"; };
    const inline = (node) => {
      if (node.nodeType === 3) return clean(node.textContent);
      if (node.nodeType !== 1 || skip.has(node.tagName) || hidden(node)) return "";
      const inner = [...node.childNodes].map(inline).join("");
      if (node.tagName === "A" && node.getAttribute("href")) return inner.trim() ? `[${inner.trim()}](${node.href})` : "";
      if (node.tagName === "B" || node.tagName === "STRONG") return inner.trim() ? `**${inner.trim()}**` : "";
      if (node.tagName === "EM" || node.tagName === "I") return inner.trim() ? `*${inner.trim()}*` : "";
      if (node.tagName === "CODE") return "`" + inner + "`";
      if (node.tagName === "IMG") return node.alt ? `![${node.alt}](${node.src})` : "";
      if (node.tagName === "BR") return "\n";
      if (node.tagName === "INPUT" || node.tagName === "TEXTAREA") return node.type === "password" ? "" : node.value ? `\`${node.value}\`` : "";
      return inner;
    };
    const out = [];
    const block = (node, depth) => {
      if (node.nodeType === 3) {
        const t = clean(node.textContent).trim();
        if (t) out.push(t);
        return;
      }
      if (node.nodeType !== 1 || skip.has(node.tagName) || hidden(node)) return;
      const tag = node.tagName;
      const m = /^H([1-6])$/.exec(tag);
      if (m) return void out.push("#".repeat(Number(m[1])) + " " + inline(node).trim());
      if (tag === "P" || tag === "SUMMARY" || tag === "LABEL" || tag === "BUTTON") return void (inline(node).trim() && out.push(inline(node).trim()));
      if (tag === "PRE") return void out.push("```\n" + node.innerText + "\n```");
      if (tag === "UL" || tag === "OL") {
        let n = 0;
        for (const li of node.children) if (li.tagName === "LI") out.push(`${"  ".repeat(depth)}${tag === "OL" ? `${++n}.` : "-"} ${inline(li).trim()}`);
        return;
      }
      if (tag === "TABLE") {
        const rows = [...node.rows].map((r) => "| " + [...r.cells].map((c) => inline(c).trim().replace(/\|/g, "\\|")).join(" | ") + " |");
        if (rows.length) out.push([rows[0], "| " + [...node.rows[0].cells].map(() => "---").join(" | ") + " |", ...rows.slice(1)].join("\n"));
        return;
      }
      if (tag === "BLOCKQUOTE") return void out.push("> " + inline(node).trim());
      const hasBlock = [...node.children].some((c) => /^(DIV|P|H[1-6]|UL|OL|TABLE|SECTION|ARTICLE|MAIN|NAV|HEADER|FOOTER|ASIDE|FORM|PRE|BLOCKQUOTE|DETAILS|FIELDSET|FIGURE|LI)$/.test(c.tagName));
      if (!hasBlock) {
        const t = inline(node).trim();
        if (t) out.push(t);
        return;
      }
      for (const c of node.childNodes) block(c, depth);
    };
    block(document.body || document.documentElement, 0);
    return `# ${document.title}\n\n<${location.href}>\n\n` + out.filter(Boolean).join("\n\n") + "\n";
  }

  // Google Workspace export endpoints for a Docs, Sheets or Slides URL.
  const GOOGLE_FORMATS = {
    document: ["pdf", "md", "docx", "txt", "odt", "rtf", "html", "epub"],
    spreadsheets: ["pdf", "xlsx", "csv", "tsv", "ods"],
    presentation: ["pdf", "pptx", "odp", "txt"],
  };
  function googleExportURL(pageURL, format) {
    let u;
    try {
      u = new core.URL(pageURL);
    } catch {
      u = null;
    }
    const m = u && u.protocol === "https:" && u.hostname === "docs.google.com" ? /^\/(document|spreadsheets|presentation)\/d\/([\w-]+)/.exec(u.pathname) : null;
    if (!m) throw new Error(`page.exportContent({ format }): expected a Google Docs, Sheets or Slides tab (https://docs.google.com/...), got ${pageURL}`);
    const [, kind, id] = m;
    const allowed = GOOGLE_FORMATS[kind];
    if (!allowed.includes(format)) throw new Error(`page.exportContent: format: expected one of ${allowed.join(", ")} for a Google ${kind === "document" ? "Docs document" : kind === "spreadsheets" ? "Sheets spreadsheet" : "Slides presentation"}, got ${JSON.stringify(format)}`);
    if (kind === "presentation") return { url: `https://docs.google.com/presentation/d/${id}/export/${format}`, kind, id };
    const gid = kind === "spreadsheets" ? /[#&?]gid=(\d+)/.exec(pageURL) : null;
    return { url: `https://docs.google.com/${kind}/d/${id}/export?format=${format}${gid ? `&gid=${gid[1]}` : ""}`, kind, id };
  }

  function youtubeVideoId(pageURL) {
    let u;
    try {
      u = new core.URL(pageURL);
    } catch {
      return null;
    }
    if (u.protocol !== "https:" || !/^(www\.|m\.)?youtube\.com$/.test(u.hostname) || u.pathname !== "/watch") return null;
    return u.searchParams.get("v");
  }

  // The hosts a YouTube caption track URL may name. Track URLs come from page
  // data and caption fetches send the session's cookies, so every caption
  // fetch (page.exportContent, sites.youtube) goes through youtubeCaptionURL.
  const YOUTUBE_CAPTION_HOSTS = Object.freeze(["www.youtube.com", "m.youtube.com", "youtube.com"]);
  // A caption track URL resolved against `base`, or null when it is not https
  // on one of YOUTUBE_CAPTION_HOSTS.
  function youtubeCaptionURL(raw, base = "https://www.youtube.com") {
    try {
      const u = new core.URL(String(raw), base);
      return u.protocol === "https:" && YOUTUBE_CAPTION_HOSTS.includes(u.hostname) ? u : null;
    } catch {
      return null;
    }
  }

  // YouTube's json3 caption format to plain text, one caption per line.
  function transcriptText(json3) {
    const lines = [];
    for (const ev of (json3 && json3.events) || []) {
      const text = (ev.segs || []).map((s) => s.utf8 || "").join("").replace(/\s+/g, " ").trim();
      if (text) lines.push(text);
    }
    return lines.join("\n") + (lines.length ? "\n" : "");
  }

  function createExporter({ fetch, fs, path, host, Buffer }) {
    let n = 0;
    const target = (options, ext) => {
      if (options.path) return path.resolve(String(options.path));
      // The session's own temporary directory (private, mode 0700).
      const dir = host.tmpdir;
      fs.mkdirSync(dir, { recursive: true });
      return path.join(dir, `export-${++n}${ext}`);
    };
    return {
      async markdown(page, options) {
        const text = await page.evaluate(pageMarkdown);
        const file = target(options, ".md");
        fs.writeFileSync(file, text);
        return file;
      },
      async google(page, pageURL, options) {
        const { url } = googleExportURL(pageURL, options.format);
        const r = await fetch(url);
        if (!r.ok) throw new Error(`page.exportContent: Google returned HTTP ${r.status} for ${url}`);
        const file = target(options, "." + options.format);
        fs.writeFileSync(file, Buffer.from(await r.arrayBuffer()));
        return file;
      },
      async youtubeTranscript(page, pageURL, options) {
        const id = youtubeVideoId(pageURL);
        if (!id) throw new Error(`page.exportContent({ transcript: true }): expected a YouTube watch page (https://www.youtube.com/watch?v=...), got ${pageURL}`);
        const tracks = await page.evaluate(() => {
          const r = window.ytInitialPlayerResponse;
          const list = r && r.captions && r.captions.playerCaptionsTracklistRenderer && r.captions.playerCaptionsTracklistRenderer.captionTracks;
          return (list || []).map((t) => ({ baseUrl: t.baseUrl, lang: t.languageCode, kind: t.kind || null }));
        });
        if (!tracks.length) throw new Error(`page.exportContent: video ${id} has no captions`);
        const usable = tracks.map((t) => ({ ...t, url: youtubeCaptionURL(t.baseUrl, pageURL) })).filter((t) => t.url);
        if (!usable.length) throw new Error(`page.exportContent: video ${id} has no captions on YouTube's caption hosts (${YOUTUBE_CAPTION_HOSTS.join(", ")})`);
        const want = options.lang ? usable.find((t) => t.lang === options.lang) : usable.find((t) => t.kind !== "asr") || usable[0];
        if (!want) throw new Error(`page.exportContent: video ${id} has no ${options.lang} captions; available: ${usable.map((t) => t.lang).join(", ")}`);
        const r = await fetch(want.url.href + "&fmt=json3");
        if (!r.ok) throw new Error(`page.exportContent: captions request returned HTTP ${r.status}`);
        const file = target(options, ".txt");
        fs.writeFileSync(file, transcriptText(await r.json()));
        return file;
      },
    };
  }

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
      // The session's own temporary directory (private, mode 0700).
      const dir = host.tmpdir;
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
    // `credentials`: "include" (the default here: cookies for every URL),
    // "same-origin" (only for the current tab's origin) or "omit" (none sent,
    // none stored). The native session checks the domain policy on every
    // redirect hop, caps the body at 64 MiB and masks secrets in text bodies.
    // `bound` ({ page, origin }, site tools only) uses that tab's cookies and
    // that origin instead of the current tab's; a closed tab fails.
    async function fetchWithCookies(input, init = {}, bound = null) {
      if (bound && (!bound.page || bound.page.isClosed())) throw new Error("fetch: the tab this request is bound to was closed");
      const page = bound ? bound.page : state.current && !state.current.isClosed() ? state.current : null;
      const base = page && /^https?:/.test(page.url()) ? page.url() : undefined;
      const url = new core.URL(String(input && input.url ? input.url : input), base).href;
      const credentials = init.credentials === undefined ? "include" : init.credentials;
      if (!["include", "same-origin", "omit"].includes(credentials)) throw new TypeError(`fetch: credentials: expected "include", "same-origin" or "omit", got ${JSON.stringify(credentials)}`);
      const origin = bound ? bound.origin || undefined : base ? new core.URL(base).origin : undefined;
      if (session.agentTools) session.agentTools.checkURL("fetch", url);
      const headers = {};
      const src = init.headers || {};
      if (typeof src.forEach === "function" && !Array.isArray(src)) src.forEach((v, k) => (headers[k] = v));
      else if (Array.isArray(src)) for (const [k, v] of src) headers[k] = v;
      else Object.assign(headers, src);
      const sendsCookies = credentials === "include" || (credentials === "same-origin" && origin === new core.URL(url).origin);
      if (!host.fetchHandlesCookies && sendsCookies && !Object.keys(headers).some((k) => k.toLowerCase() === "cookie")) {
        const scope = page && !String(page._targetId).startsWith("lazy:") ? { targetId: page._targetId } : {};
        const cookies = await session.call("cookies.get", { ...scope, urls: [url] }).catch(() => []);
        if (cookies.length) headers.cookie = cookies.map((c) => `${c.name}=${c.value}`).join("; ");
      }
      const body = init.body === undefined || init.body === null ? undefined : Buffer.from(init.body).toString("base64");
      const targetId = page && !String(page._targetId).startsWith("lazy:") ? page._targetId : undefined;
      const r = await host.fetch(url, { method: (init.method || "GET").toUpperCase(), headers, body, targetId, credentials, origin });
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
      // Any tab tabs.list({ all: true }) lists can be attached (a claim),
      // except one another running session opened; the driver refuses
      // those too.
      const list = await session.call("tabs.list", { all: true });
      const row = list.find((t) => t.targetId === String(id));
      if (!row) throw new Error(`No open tab with id ${JSON.stringify(String(id))}; see tabs.list()`);
      if (row.ownerSession) throw new Error(`Tab ${JSON.stringify(String(id))} belongs to the REPL session ${JSON.stringify(row.ownerSession)}, which is still running; a session drives only the tabs it opened and the user's tabs`);
      const page = session.pageFor(String(id));
      await page._syncInfo().catch(() => {});
      return page;
    }

    session.exporter = createExporter({ fetch: fetchWithCookies, fs, path, host, Buffer });

    const tabs = {
      // `{ all: true }` also lists browser tabs in the user's other
      // workspaces and windows; tabs.use(id) attaches any of them but one
      // another running session opened (`ownedBy` names that session).
      async list(options = {}) {
        const list = await session.call("tabs.list", options && options.all ? { all: true } : {});
        const current = state.current && state.current._targetId;
        return list.map((t) => {
          // state: "live", "hibernated" (cmux unloaded the hidden page to
          // save memory; the next call on it loads it again), "waking" or
          // "crashed" (page.reload() loads it again).
          const row = { id: t.targetId, title: t.title, url: t.url, active: !!t.active, current: t.targetId === current, state: t.state || "live" };
          if (options && options.all) row.workspace = t.windowId === undefined ? null : t.windowId;
          // A tab another running session opened: listed, not usable.
          if (t.ownerSession) row.ownedBy = t.ownerSession;
          return row;
        });
      },
      // Loads each URL in a background tab, extracts it and closes the tab;
      // the current tab does not change. format: "text" (default),
      // "markdown", "html" or "snapshot".
      async content(input, options = {}) {
        const opts = Array.isArray(input) || typeof input === "string" ? { ...options, urls: [].concat(input) } : { ...(input || {}) };
        const urls = opts.urls;
        if (!Array.isArray(urls) || !urls.length || urls.some((u) => typeof u !== "string" || !u)) throw new Error(`tabs.content: urls: expected a non-empty array of URLs, got ${JSON.stringify(urls)}`);
        const format = opts.format || "text";
        if (!["text", "markdown", "html", "snapshot"].includes(format)) throw new Error(`tabs.content: format: expected one of text, markdown, html, snapshot, got ${JSON.stringify(format)}`);
        const timeout = opts.timeout !== undefined ? opts.timeout : 30000;
        const one = async (url) => {
          const page = await session.newPage(undefined, { background: true });
          try {
            const response = await page.goto(url, { timeout, waitUntil: opts.waitUntil || "load" });
            let content;
            if (format === "html") content = await page.content();
            else if (format === "snapshot") content = String((await ns.snapshot.takeSnapshot(page, undefined, { maxChars: Infinity })).tree);
            else if (format === "markdown") content = await page.evaluate(ns.api.pageMarkdown);
            else content = await page.evaluate(() => (document.body ? document.body.innerText : ""));
            return { url: page.url(), title: await page.title(), status: response ? response.status() : null, content };
          } catch (e) {
            return { url, title: null, status: null, content: null, error: String((e && e.message) || e) };
          } finally {
            await page.close().catch(() => {});
          }
        };
        const out = [];
        // A few at a time, in the order given.
        for (let i = 0; i < urls.length; i += 4) out.push(...(await Promise.all(urls.slice(i, i + 4).map(one))));
        return out;
      },
      // cmux's browser history, most recent first: [{ url, title, dateVisited }].
      async history(options = {}) {
        if (options === null || typeof options !== "object") throw new Error(`tabs.history: options: expected an object, got ${JSON.stringify(options)}`);
        const limit = options.limit === undefined ? 100 : options.limit;
        if (!Number.isInteger(limit) || limit < 1) throw new Error(`tabs.history: limit: expected a positive integer, got ${JSON.stringify(limit)}`);
        const date = (v, name) => {
          if (v === undefined) return undefined;
          const d = v instanceof Date ? v : new Date(v);
          if (isNaN(d.getTime())) throw new Error(`tabs.history: ${name}: expected a date, got ${JSON.stringify(v)}`);
          return d.getTime();
        };
        const from = date(options.from, "from");
        const to = date(options.to, "to");
        const queries = [].concat(options.query === undefined ? [] : options.query, options.queries || []).map(String).filter(Boolean);
        const rows = await session.call("history.search", { queries, from, to, limit });
        return rows.map((r) => ({ url: r.url, title: r.title || "", dateVisited: new Date(r.dateVisited).toISOString() }));
      },
      async open(url, options = {}) {
        if (url !== undefined && url !== null && url !== "") ns.checkNavigableURL("tabs.open", url);
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
      fetch: (input, init) => fetchWithCookies(input, init),
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
    // Site tools (docs/browser-repl/site-tools.md), built on first use.
    if (ns.sites) {
      let sites = null;
      Object.defineProperty(globals, "sites", {
        get: () =>
          sites ||
          (sites = ns.sites.createSites({
            session,
            host,
            fetch: (input, init) => fetchWithCookies(input, init),
            fetchFrom: (page, origin) => (input, init) => fetchWithCookies(input, init, { page, origin }),
            fs,
            path,
            Buffer,
            URL: core.URL,
            currentPage,
            snapshot,
          })),
        enumerable: true,
        configurable: true,
      });
    }
    // Reference C parity tools (agent-tools.js): secrets, domain policy,
    // storage state, downloads, recording, search, custom tools, Markdown and
    // structured extraction.
    if (ns.agentTools) ns.agentTools.install({ session, host, globals, sessionApi, fetch: fetchWithCookies, fs, path, currentPage, tabs, show });
    return { globals, show, importModule, state };
  }

  ns.api = { createGlobals, createPath, createFs, inspect, Image, imageSize, pageMarkdown, googleExportURL, youtubeVideoId, youtubeCaptionURL, YOUTUBE_CAPTION_HOSTS, transcriptText };
})(typeof globalThis !== "undefined" ? globalThis : this);
