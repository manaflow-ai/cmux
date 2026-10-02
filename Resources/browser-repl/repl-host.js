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

    // Cells run one at a time in submission order. The queue is plain state,
    // not a promise chain: when the app terminates a runaway script,
    // JavaScriptCore drops the promise jobs that were pending, so a chain
    // could never advance again. Each cell settles its caller's promise
    // directly, and cancel() settles the running one and starts the next.
    const waiting = [];
    let running = null;
    function pump() {
      if (running || !waiting.length) return;
      const cell = waiting.shift();
      running = cell;
      let started;
      try {
        started = run(cell.code);
      } catch (e) {
        started = Promise.resolve({ ok: false, error: formatError(e), exception: e, ms: 0 });
      }
      started.then(cell.finish, (e) => cell.finish({ ok: false, error: formatError(e), exception: e, ms: 0 }));
    }
    return {
      scope,
      evaluate(code) {
        return new Promise((resolve) => {
          const cell = {
            code,
            done: false,
            finish(r) {
              if (cell.done) return;
              cell.done = true;
              if (running === cell) running = null;
              resolve(r);
              pump();
            },
          };
          waiting.push(cell);
          pump();
        });
      },
      // Ends the running cell now (the app calls this when a cell times
      // out): its evaluate() result is { ok: false, error: message } and the
      // next cell starts. Work the cell already scheduled is not undone.
      cancel(message) {
        if (!running) return false;
        running.finish({ ok: false, error: String(message), cancelled: true, ms: 0 });
        return true;
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

  // Output of one call. Past `maxOutput` characters (0 or Infinity: no
  // limit) the rest of the call's output goes to a file instead of the
  // agent's context: the head prints, then a line naming the file, and at
  // the end of the call the last lines and a summary. The file holds all of
  // the call's output, the printed part too. Agent harnesses cut tool output
  // past about 30,000 characters (Claude Code keeps a 2,000-character
  // preview and a file; Codex keeps 10,000 tokens, head and tail), so the
  // default stays under both and the REPL decides what is kept.
  const DEFAULT_MAX_OUTPUT = 25000;
  const commas = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const spillCounters = new WeakMap();

  function createOutputGate(host, { maxOutput } = {}) {
    const cap = maxOutput === undefined || maxOutput === null ? DEFAULT_MAX_OUTPUT : maxOutput;
    if (!(cap > 0) || cap === Infinity) return { print: (level, text) => host.print(level, text), finish() {}, spilled: () => null };
    const headCap = Math.floor(cap * 0.8);
    // Room for the last lines; a cap too small for them shows none.
    const tailCap = Math.max(0, cap - headCap - 400);
    const printedTexts = [];
    let shown = 0;
    let total = 0;
    let file = null;
    let tail = "";
    const write = (text, append) => {
      try {
        host.fsOp("writeFile", { path: file, base64: ns.core.Buffer.from(text, "utf8").toString("base64"), append });
      } catch (e) {
        if (host.console) host.console.error(`cmux browser repl: could not write ${file}: ${e.message}`);
      }
    };
    const spill = () => {
      const dir = `${host.tmpdir}/cmux-browser-repl/${String(host.sessionId || "session").replace(/[^\w.-]/g, "_")}`;
      try {
        host.fsOp("mkdir", { path: dir, recursive: true });
      } catch {}
      const n = (spillCounters.get(host) || 0) + 1;
      spillCounters.set(host, n);
      file = `${dir}/output-${n}.txt`;
      write(printedTexts.join(""), false);
      printedTexts.length = 0;
    };
    return {
      print(level, text) {
        text = String(text);
        total += text.length + 1;
        if (!file) {
          if (shown + text.length + 1 <= headCap) {
            shown += text.length + 1;
            printedTexts.push(text + "\n");
            host.print(level, text);
            return;
          }
          printedTexts.push(text + "\n");
          spill();
          // The part of this text that still fits, cut at a line end, or
          // inside a line longer than the room.
          const room = Math.max(0, headCap - shown);
          const cut = text.lastIndexOf("\n", room);
          const head = cut > 0 ? text.slice(0, cut) : room > 0 ? text.slice(0, room) + "…" : "";
          if (head) {
            shown += head.length + 1;
            host.print(level, head);
          }
          tail = text.slice(cut > 0 ? cut + 1 : room);
          host.print("info", `# output continues in ${file}`);
          return;
        }
        write(text + "\n", true);
        tail = (tail ? tail + "\n" : "") + text;
        if (tail.length > 4 * tailCap) tail = tail.slice(-2 * tailCap);
      },
      // The last lines and the summary, once the call has printed everything.
      finish() {
        if (!file) return;
        if (!tailCap) tail = "";
        let last = tail.length > tailCap ? tail.slice(-tailCap) : tail;
        if (last.length < tail.length) {
          const nl = last.indexOf("\n");
          // Whole lines when one fits, else the end of the last line.
          last = nl >= 0 ? last.slice(nl + 1) : "…" + last;
        }
        if (last) {
          shown += last.length + 1;
          host.print("log", `# … last lines:\n${last}`);
        }
        host.print("info", `# output truncated: ${commas(Math.min(shown, total))} of ${commas(total)} characters shown; full output: ${file}`);
        file = null;
      },
      spilled: () => file,
    };
  }

  // One REPL session over one driver. The last expression's value prints
  // (awaited first when it is a promise); undefined prints nothing.
  // `evaluate(code, { maxOutput })` caps what one call prints (above).
  function createBrowserRepl({ host, driver }) {
    const core = ns.core;
    const session = new core.Session({ driver, host });
    let gate = null;
    // Everything the runtime prints goes through the current call's gate.
    // Registered secrets (agent-tools.js) never reach output, the output
    // spill file or an error message.
    const redact = (text) => (session.agentTools ? session.agentTools.redactText(text) : text);
    const gatedHost = Object.create(host, {
      print: { value: (level, text) => (gate ? gate.print(level, redact(text)) : host.print(level, redact(text))) },
    });
    const api = ns.api.createGlobals(session, gatedHost);
    const repl = createReplSession({ host: gatedHost, globals: [timerGlobals(gatedHost, api.importModule), api.globals] });
    const redactError = (r) => {
      if (r.ok || !session.agentTools) return r;
      if (r.exception instanceof Error) {
        try {
          r.exception.message = redact(r.exception.message);
        } catch {}
      }
      return Object.assign(r, { error: redact(r.error) });
    };
    return {
      session,
      api,
      scope: repl.scope,
      redact,
      async evaluate(code, { maxOutput } = {}) {
        const own = createOutputGate(host, { maxOutput });
        gate = own;
        try {
          const r = await repl.evaluate(code);
          if (r.ok) {
            try {
              api.show(r.value);
            } catch (e) {
              return redactError({ ok: false, error: formatError(e), exception: e, ms: r.ms });
            }
          }
          return redactError(r);
        } finally {
          own.finish();
          if (gate === own) gate = null;
        }
      },
      cancel: (message) => repl.cancel(message),
      dispose: () => session.dispose(),
    };
  }

  // A timer delay in milliseconds: NaN, negative and non-numeric delays are
  // 0 and longer ones are capped at 2^31-1 ms (about 24.8 days), as browsers
  // and Node cap setTimeout.
  const MAX_TIMER_DELAY = 2147483647;
  function timerDelay(ms) {
    const n = Number(ms);
    if (!(n > 0)) return 0;
    return n >= MAX_TIMER_DELAY ? MAX_TIMER_DELAY : Math.floor(n);
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
        native.setTimer(id, timerDelay(ms), false);
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
    // `optionsJSON` (optional): { "maxOutput": characters, 0 for no limit }.
    root.__cmuxReplEval = async (code, optionsJSON) => {
      if (!repl) repl = createBrowserRepl({ host, driver });
      const options = typeof optionsJSON === "string" && optionsJSON ? JSON.parse(optionsJSON) : {};
      const r = await repl.evaluate(code, { maxOutput: options.maxOutput });
      if (!r.ok) throw r.exception || new Error(r.error);
      return undefined;
    };
    root.__cmuxReplCancel = (message) => (repl ? repl.cancel(message) : false);
    root.__cmuxFormatError = (e) => (repl ? repl.redact(formatError(e)) : formatError(e));
  }

  ns.replHost = { timerDelay, rewriteTopLevel, createReplSession, createBrowserRepl, createOutputGate, DEFAULT_MAX_OUTPUT, formatError, installNativeHost };
  installNativeHost();
})(typeof globalThis !== "undefined" ? globalThis : this);
