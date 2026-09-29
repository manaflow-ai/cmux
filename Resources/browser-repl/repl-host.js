// REPL host: evaluates code cells with top-level await and keeps top-level
// const/let/var/function/class bindings across cells.
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
  // routed to the REPL's own node:fs, node:path and node:os modules.
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

  // Creates a REPL session. `globals` are merged into the scope; a global
  // may be an accessor (`page`).
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
  function timerGlobals(host, importModule) {
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
      // import("node:fs") and friends return the same modules as the globals.
      __cmuxImport: (specifier) => Promise.resolve().then(() => importModule(specifier)),
    };
  }

  // One REPL session over one driver. The last expression's value prints
  // (awaited first when it is a promise); undefined prints nothing.
  function createBrowserRepl({ host, driver }) {
    const core = ns.core;
    const session = new core.Session({ driver, host });
    const api = ns.api.createGlobals(session, host);
    const repl = createReplSession({ host, globals: [timerGlobals(host, api.importModule), api.globals] });
    return {
      session,
      api,
      scope: repl.scope,
      async evaluate(code) {
        const r = await repl.evaluate(code);
        if (r.ok) {
          try {
            api.show(r.value);
          } catch (e) {
            return { ok: false, error: formatError(e), exception: e, ms: r.ms };
          }
        }
        return r;
      },
      dispose: () => session.dispose(),
    };
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
    const host = {
      get workDir() {
        return native.cwd;
      },
      get sessionId() {
        return native.sessionId;
      },
      tmpdir: native.tmpdir,
      homedir: native.homedir,
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
      print: (level, text) => native.print(level, text),
      readResource: (relativePath) => native.readResource(relativePath),
      fsOp(op, args) {
        const r = JSON.parse(native.fs(op, JSON.stringify(args)));
        if (r.error) {
          const e = new Error(r.error.message);
          e.code = r.error.code;
          throw e;
        }
        return r.ok;
      },
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
    };
    host.console = { error: (text) => native.print("error", text) };
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
      if (!repl) repl = createBrowserRepl({ host, driver });
      const r = await repl.evaluate(code);
      if (!r.ok) throw r.exception || new Error(r.error);
      return undefined;
    };
    root.__cmuxFormatError = (e) => formatError(e);
  }

  ns.replHost = { rewriteTopLevel, createReplSession, createBrowserRepl, formatError, installNativeHost };
  installNativeHost();
})(typeof globalThis !== "undefined" ? globalThis : this);
