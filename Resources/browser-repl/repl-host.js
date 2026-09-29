// REPL host: evaluates code cells with top-level await and keeps top-level
// const/let/var/function/class bindings across cells, as `aside repl` does.
//
// Cells run inside `with (scope)` in a sloppy async function. Top-level
// declarations are rewritten into assignments on the scope object, so later
// cells (and closures from earlier cells) see the same bindings.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});

  function acornApi() {
    const acorn = root.acorn || (ns.vendor && ns.vendor.acorn);
    if (!acorn) throw new Error("acorn is not loaded");
    return acorn;
  }

  function patternNames(node, out) {
    if (!node) return out;
    switch (node.type) {
      case "Identifier":
        out.push(node.name);
        break;
      case "ObjectPattern":
        for (const p of node.properties) patternNames(p.type === "RestElement" ? p.argument : p.value, out);
        break;
      case "ArrayPattern":
        for (const e of node.elements) patternNames(e, out);
        break;
      case "RestElement":
        patternNames(node.argument, out);
        break;
      case "AssignmentPattern":
        patternNames(node.left, out);
        break;
    }
    return out;
  }

  // Dynamic import() cannot run in a Function-constructed cell (and
  // JavaScriptCore has no module loader here), so every ImportExpression is
  // routed through the host's optional importModule().
  function importExpressions(node, out) {
    if (!node || typeof node.type !== "string") return out;
    if (node.type === "ImportExpression") out.push(node);
    for (const key of Object.keys(node)) {
      const v = node[key];
      if (Array.isArray(v)) v.forEach((c) => importExpressions(c, out));
      else if (v && typeof v === "object" && typeof v.type === "string") importExpressions(v, out);
    }
    return out;
  }

  // Rewrites top-level declarations of one cell. Returns the new source, the
  // declared names (the caller predefines them on the scope so assignments
  // inside `with` land there), and whether the last statement is an
  // expression whose value is the cell result.
  function rewriteTopLevel(code) {
    const ast = acornApi().parse(code, {
      ecmaVersion: "latest",
      sourceType: "script",
      allowAwaitOutsideFunction: true,
      allowReturnOutsideFunction: false,
      allowHashBang: true,
    });
    const imports = importExpressions(ast, []);
    if (imports.length) {
      // Replace the `import` keyword (6 chars) from the end so offsets stay valid.
      for (const node of imports.sort((a, b) => b.start - a.start)) {
        code = code.slice(0, node.start) + "__cmuxImport" + code.slice(node.start + 6);
      }
      return rewriteTopLevel(code);
    }
    const names = [];
    const hoisted = [];
    let out = "";
    let cursor = 0;
    const body = ast.body;
    body.forEach((stmt, index) => {
      out += code.slice(cursor, stmt.start);
      cursor = stmt.end;
      const text = code.slice(stmt.start, stmt.end);
      if (stmt.type === "VariableDeclaration") {
        const parts = [];
        for (const decl of stmt.declarations) {
          patternNames(decl.id, names);
          const target = code.slice(decl.id.start, decl.id.end);
          const init = decl.init ? code.slice(decl.init.start, decl.init.end) : "undefined";
          if (decl.id.type === "Identifier") parts.push(`${target} = ${init}`);
          else parts.push(`(${target} = ${init})`);
        }
        out += `;${parts.map((p) => `void (${p})`).join("; ")};`;
      } else if (stmt.type === "FunctionDeclaration") {
        names.push(stmt.id.name);
        hoisted.push(`${stmt.id.name} = ${text};`);
      } else if (stmt.type === "ClassDeclaration") {
        names.push(stmt.id.name);
        out += `;${stmt.id.name} = ${text};`;
      } else if (index === body.length - 1 && stmt.type === "ExpressionStatement") {
        const expr = code.slice(stmt.expression.start, stmt.expression.end);
        out += `;__cmuxLast = (${expr});`;
      } else {
        out += text;
      }
    });
    out += code.slice(cursor);
    return { source: hoisted.join("\n") + (hoisted.length ? "\n" : "") + out, names: [...new Set(names)] };
  }

  function formatError(e) {
    if (!e) return "Error: undefined";
    if (e instanceof Error) {
      const name = e.name || "Error";
      return `${name}: ${e.message}`;
    }
    return String(e);
  }

  // Creates a REPL session. `globals` are merged into the scope; dialect
  // globals may define getters (Aside's `page`, `tabs`).
  function createReplSession({ host, globals }) {
    const scope = Object.create(null);
    for (const g of globals) {
      for (const key of Object.getOwnPropertyNames(g)) {
        Object.defineProperty(scope, key, Object.getOwnPropertyDescriptor(g, key));
      }
    }
    let queue = Promise.resolve();

    async function run(code) {
      const started = host.now ? host.now() : Date.now();
      let rewritten;
      try {
        rewritten = rewriteTopLevel(code);
      } catch (e) {
        return { ok: false, error: `SyntaxError: ${e.message}`, ms: 0 };
      }
      for (const name of rewritten.names) {
        if (!(name in scope)) scope[name] = undefined;
        else {
          const d = Object.getOwnPropertyDescriptor(scope, name);
          if (d && !d.writable && !d.set) Object.defineProperty(scope, name, { value: undefined, writable: true, configurable: true, enumerable: true });
        }
      }
      let fn;
      try {
        // Function() keeps the body sloppy, which `with` requires.
        fn = new Function("__cmuxScope", `return async function () { let __cmuxLast; with (__cmuxScope) {\n${rewritten.source}\n} return __cmuxLast; };`)(scope);
      } catch (e) {
        return { ok: false, error: `SyntaxError: ${e.message}`, ms: 0 };
      }
      try {
        const value = await fn();
        return { ok: true, value, ms: (host.now ? host.now() : Date.now()) - started };
      } catch (e) {
        return { ok: false, error: formatError(e), exception: e, ms: (host.now ? host.now() : Date.now()) - started };
      }
    }

    return {
      scope,
      evaluate(code) {
        const next = queue.then(() => run(code));
        queue = next.catch(() => {});
        return next;
      },
    };
  }

  // Timer globals for user code, backed by the host (JavaScriptCore has none).
  function timerGlobals(host) {
    const intervals = new Map();
    let nextInterval = 1;
    return {
      setTimeout: (fn, ms, ...args) => host.setTimeout(() => fn(...args), ms || 0),
      clearTimeout: (id) => host.clearTimeout(id),
      setInterval(fn, ms, ...args) {
        const id = nextInterval++;
        const tick = () => {
          if (!intervals.has(id)) return;
          intervals.set(id, host.setTimeout(tick, ms || 0));
          fn(...args);
        };
        intervals.set(id, host.setTimeout(tick, ms || 0));
        return id;
      },
      clearInterval(id) {
        const t = intervals.get(id);
        intervals.delete(id);
        if (t !== undefined) host.clearTimeout(t);
      },
      queueMicrotask: (fn) => Promise.resolve().then(fn),
      __cmuxImport: (specifier) => {
        if (typeof host.importModule === "function") return host.importModule(String(specifier));
        return Promise.reject(new Error(`import(${JSON.stringify(String(specifier))}) is not available in the cmux browser REPL`));
      },
    };
  }

  // One REPL with both dialects over one driver: `snapshot(page)` and
  // `agent...tab.ax` address the same tabs.
  function createBrowserRepl({ host, driver, workDir }) {
    const core = ns.core;
    const session = new core.Session({ driver, host });
    const aside = ns.aside.createAsideGlobals(session, { workDir: workDir || host.workDir });
    const chatgpt = ns.chatgpt ? ns.chatgpt.createChatgptGlobals(session, { workDir: workDir || host.workDir }) : {};
    const extras = { URL: core.URL, URLSearchParams: core.URLSearchParams };
    const repl = createReplSession({ host, globals: [timerGlobals(host), extras, chatgpt, aside] });
    return {
      session,
      scope: repl.scope,
      evaluate: (code) => repl.evaluate(code),
      dispose: () => session.dispose(),
    };
  }

  // Node built-ins for import() in the app (ChatGPT's REPL is Node): exactly
  // fs, fs/promises, path and os. fs calls pass scope "chatgpt", so the
  // native sandbox admits the session cwd and the user's temp directory.
  function nodeModule(specifier, fsOp, native) {
    const name = specifier.replace(/^node:/, "");
    const Buffer = ns.core.Buffer;
    const path = ns.aside.path;
    const op = (name, args) => fsOp(name, Object.assign({ scope: "chatgpt" }, args));
    const abs = (p) => path.resolve(native.cwd, String(p && p.href ? decodeURIComponent(p.pathname) : p));
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
      mkdirSync: (p, o) => void op("mkdir", { path: abs(p), recursive: !!(o && o.recursive) }),
      readdirSync: (p) => op("readdir", { path: abs(p) }).map((e) => e.name),
      statSync: (p) => statOf(op("stat", { path: abs(p) })),
      existsSync: (p) => op("exists", { path: abs(p) }),
      rmSync: (p, o) => void op("rm", { path: abs(p), recursive: !!(o && o.recursive), force: !!(o && o.force) }),
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
    for (const [key, fn] of Object.entries(sync)) {
      if (key === "existsSync") continue;
      promises[key.replace(/Sync$/, "")] = async (...args) => fn(...args);
    }
    promises.access = async (p) => {
      if (!sync.existsSync(p)) {
        const e = new Error(`ENOENT: no such file or directory, access '${p}'`);
        e.code = "ENOENT";
        throw e;
      }
    };
    const os = {
      tmpdir: () => native.tmpdir,
      homedir: () => native.homedir,
      platform: () => "darwin",
      type: () => "Darwin",
      EOL: "\n",
    };
    switch (name) {
      case "fs":
        return Object.assign({ promises, default: Object.assign({ promises }, sync) }, sync);
      case "fs/promises":
        return Object.assign({ default: promises }, promises);
      case "path":
        return Object.assign({ default: path }, path);
      case "os":
        return Object.assign({ default: os }, os);
      default:
        throw new Error(`Cannot import ${specifier}: cmux browser repl supports node:fs, node:path, node:os`);
    }
  }

  // Adapts the app's `__cmuxNative` object (driver-protocol.md, "Native host
  // contract") to the `host` and `driver` objects the runtime uses, and
  // defines the entry points the app calls.
  function installNativeHost() {
    const native = root.__cmuxNative;
    if (!native || root.__cmuxReplEval) return;
    const pending = new Map();
    const timers = new Map();
    const listeners = new Map();
    let nextCall = 1;
    let nextTimer = 1;
    root.__cmuxHostOnResult = (id, errorJSON, resultJSON) => {
      const p = pending.get(id);
      if (!p) return;
      pending.delete(id);
      if (errorJSON !== null && errorJSON !== undefined) {
        const info = JSON.parse(errorJSON);
        const e = new Error(info.message);
        e.code = info.code;
        p.reject(e);
      } else p.resolve(resultJSON === null || resultJSON === undefined ? undefined : JSON.parse(resultJSON));
    };
    root.__cmuxHostOnTimer = (id) => {
      const t = timers.get(id);
      if (!t) return;
      timers.delete(id);
      t();
    };
    root.__cmuxHostOnEvent = (name, payloadJSON) => {
      const payload = payloadJSON ? JSON.parse(payloadJSON) : {};
      for (const h of listeners.get(name) || []) h(payload);
    };
    const callAsync = (fn) => new Promise((resolve, reject) => {
      const id = nextCall++;
      pending.set(id, { resolve, reject });
      fn(id);
    });
    const fsOp = (op, args) => {
      const r = JSON.parse(native.fs(op, JSON.stringify(args)));
      if (r.error) {
        const e = new Error(r.error.message);
        e.code = r.error.code;
        throw e;
      }
      return r.ok;
    };
    const host = {
      workDir: native.cwd,
      nativeSandbox: true,
      setTimeout(fn, ms) {
        const id = nextTimer++;
        timers.set(id, fn);
        native.setTimer(id, Math.max(0, ms || 0), false);
        return id;
      },
      clearTimeout(id) {
        if (!timers.delete(id)) return;
        native.clearTimer(id);
      },
      now: () => Date.now(),
      console: {
        log: (text) => native.print("log", text),
        error: (text) => native.print("error", text),
      },
      display: (value) => native.print("log", typeof value === "string" ? value : JSON.stringify(value)),
      fetchHandlesCookies: true,
      async fetch(url, init) {
        const r = await callAsync((id) => native.fetch(id, JSON.stringify({
          url,
          method: init.method,
          headers: Object.entries(init.headers || {}),
          bodyBase64: init.body,
          targetId: init.targetId,
        })));
        return { url: r.url, status: r.status, statusText: r.statusText, headers: Object.fromEntries(r.headers || []), base64: r.bodyBase64 || "", redirected: r.redirected };
      },
      fs: {
        readFile: async (p) => fsOp("readFile", { path: p }),
        writeFile: async (p, base64) => fsOp("writeFile", { path: p, base64 }),
        appendFile: async (p, base64) => fsOp("writeFile", { path: p, base64, append: true }),
        mkdir: async (p, recursive) => fsOp("mkdir", { path: p, recursive }),
        readdir: async (p) => fsOp("readdir", { path: p }).map((e) => e.name),
        stat: async (p) => {
          const s = fsOp("stat", { path: p });
          return { size: s.size, mtimeMs: s.mtimeMs, isFile: s.type === "file", isDirectory: s.type === "directory" };
        },
        rm: async (p, recursive) => fsOp("rm", { path: p, recursive, force: true }),
        exists: async (p) => fsOp("exists", { path: p }),
        realpath: (p) => fsOp("resolve", { path: p }),
      },
    };
    host.importModule = async (specifier) => nodeModule(String(specifier), fsOp, native);
    const driver = {
      call: (method, params) => callAsync((id) => native.driverCall(id, method, JSON.stringify(params || {}))),
      on(event, handler) {
        if (!listeners.has(event)) listeners.set(event, new Set());
        listeners.get(event).add(handler);
        return () => listeners.get(event).delete(handler);
      },
      capabilities: () => native.capabilities || [],
    };
    let repl = null;
    root.__cmuxReplEval = async (code) => {
      if (!repl) repl = createBrowserRepl({ host, driver, workDir: native.cwd });
      const r = await repl.evaluate(code);
      if (!r.ok) throw r.exception || new Error(r.error);
      return r.value;
    };
    root.__cmuxFormatError = (e) => formatError(e);
  }

  ns.replHost = { rewriteTopLevel, createReplSession, createBrowserRepl, formatError, installNativeHost };
  installNativeHost();
})(typeof globalThis !== "undefined" ? globalThis : this);
