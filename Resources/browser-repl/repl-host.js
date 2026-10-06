// REPL host: evaluates code cells with top-level await and keeps top-level
// const/let/var/function/class bindings across cells.
//
// Cells run inside `with (scope)` in a sloppy async function. Top-level
// declarations are rewritten into assignments on the scope object, so later
// cells (and closures from earlier cells) see the same bindings.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  // Taken before any cell runs, so a cell that replaces the global Error
  // does not change how the runtime reads a stack.
  const StackError = Error;

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

  // Output reaches the caller's terminal, and page text (titles, names,
  // values, URLs, error messages) is in it, so every printed line passes
  // here: C0 controls but newline and tab, DEL and C1 controls print as
  // visible escapes (`\u001b`), which no terminal interprets. A CRLF is a
  // newline; a lone CR, which could overwrite a printed line, is escaped.
  // The escapes are JSON's (`\r`, `\b`, `\f`, else `\u00xx`), so the native
  // session still masks a registered secret that holds a control character
  // (it masks a value's JSON-escaped form too).
  const CONTROLS = /\r\n|[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g;
  const SHORT_ESCAPES = { "\r": "\\r", "\b": "\\b", "\f": "\\f" };
  // The most characters one print keeps, in the output and its spill
  // file: it is cut before it is escaped, encoded or written, so one huge
  // string cannot make those copies.
  const MAX_PRINT_CHARS = 16000000;

  function printable(text) {
    let s = String(text);
    const given = s.length;
    if (given > MAX_PRINT_CHARS) s = s.slice(0, MAX_PRINT_CHARS);
    s = s.replace(CONTROLS, (c) => (c === "\r\n" ? "\n" : SHORT_ESCAPES[c] || "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0")));
    // Escapes can make it longer again.
    if (given <= MAX_PRINT_CHARS && s.length <= MAX_PRINT_CHARS) return s;
    const count = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    return `${s.slice(0, MAX_PRINT_CHARS)}…\n# this print was cut after ${count(MAX_PRINT_CHARS)} characters (${count(given)} were given)`;
  }

  function formatError(e) {
    if (!e) return "Error: undefined";
    if (e instanceof Error) {
      const name = e.name || "Error";
      return printable(`${name}: ${e.message}`);
    }
    return printable(String(e));
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
    // Which cell's code runs now. Each cell body runs as a function named
    // __cmuxCell<seq>, which the stack names in every engine, also after an
    // await resumes it, and the engines' async stacks name it under an
    // async function the cell awaits. The cell's sequence number is the
    // token its leftover work carries: once the app cancelled the cell
    // (it timed out), that work is refused host and driver calls
    // (isCancelledWork) and its page listeners are dropped. Agent code can
    // change what a stack shows; this keeps a cell's own stale work from
    // acting late, it is not a guard (the app cancels the cell's timers,
    // fetches and driver calls itself).
    let cellSeq = 0;
    const cancelledSeqs = new Set();
    const CELL_FRAME = /__cmuxCell(\d+)\b/g;
    // The cells whose bodies are on the stack now, innermost first.
    function cellsOnStack() {
      const limit = StackError.stackTraceLimit;
      let stack = "";
      try {
        StackError.stackTraceLimit = Infinity;
        stack = String(new StackError().stack || "");
      } catch {
        // A non-writable limit: read the stack as it is.
        stack = String(new StackError().stack || "");
      } finally {
        try {
          StackError.stackTraceLimit = limit;
        } catch {}
      }
      return Array.from(stack.matchAll(CELL_FRAME), (m) => Number(m[1]));
    }
    const runningOnStack = (seqs) => !!running && running.seq !== undefined && seqs.includes(running.seq);
    // Whether the code running now is a cancelled cell's leftover work: a
    // cancelled cell's body is on the stack and the running cell's is not
    // (a function the cancelled cell defined still works for the cell that
    // calls it).
    function isCancelledWork() {
      if (!cancelledSeqs.size) return false;
      const seqs = cellsOnStack();
      return !runningOnStack(seqs) && seqs.some((seq) => cancelledSeqs.has(seq));
    }
    // The cell whose code runs now (the running cell when its body is on
    // the stack, else the innermost cell there), or undefined outside every
    // cell (a timer or listener callback).
    function ownerOnStack() {
      const seqs = cellsOnStack();
      return runningOnStack(seqs) ? running.seq : seqs[0];
    }
    // The console a cell's code sees. Once the cell is cancelled, output its
    // own leftover work prints later (a timer, a listener, an await that
    // resumes) is dropped, so it never lands in another cell. A function
    // the cancelled cell defined still prints when the running cell calls
    // it: the running cell's body is then on the stack.
    function cellConsole(cell) {
      const base = scope.console;
      if (!base || typeof base !== "object") return base;
      const prints = () => {
        if (!cell.cancelled) return true;
        if (!running || running === cell || running.seq === undefined) return false;
        return runningOnStack(cellsOnStack());
      };
      return new Proxy(base, {
        get(target, key) {
          const value = target[key];
          return typeof value === "function" ? (...args) => (prints() ? value.apply(target, args) : undefined) : value;
        },
      });
    }

    async function run(code, cell) {
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
        // The cell body runs in a named function inside `with`, so its
        // `console` parameter shadows the scope's console and everything
        // else resolves through the scope.
        const owner = cell || {};
        owner.seq = ++cellSeq;
        fn = new Function("__cmuxScope", "__cmuxConsole", `return async function () { let __cmuxLast; with (__cmuxScope) { await (async function __cmuxCell${owner.seq}(console) {\n${rewritten.source}\n})(__cmuxConsole); } return __cmuxLast; };`)(scope, cellConsole(owner));
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
        started = run(cell.code, cell);
      } catch (e) {
        started = Promise.resolve({ ok: false, error: formatError(e), exception: e, ms: 0 });
      }
      started.then(cell.finish, (e) => cell.finish({ ok: false, error: formatError(e), exception: e, ms: 0 }));
    }
    return {
      scope,
      isCancelledWork,
      ownerOnStack,
      isCancelledCell: (seq) => cancelledSeqs.has(seq),
      // `id` names the cell for cancel().
      evaluate(code, { id } = {}) {
        return new Promise((resolve) => {
          const cell = {
            code,
            id,
            done: false,
            cancelled: false,
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
      // next cell starts. The app cancels the cell's timers, fetches and
      // driver calls itself.
      // With an `id`, only that cell is cancelled: a late cancel for a cell
      // that already ended never ends the next one.
      cancel(message, id) {
        if (!running || (id !== undefined && running.id !== id)) return false;
        running.cancelled = true;
        if (running.seq !== undefined) cancelledSeqs.add(running.seq);
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
  // limit below HARD_MAX_OUTPUT) the rest of the call's output goes to a file instead of the
  // agent's context: the head prints, then a line naming the file, and at
  // the end of the call the last lines and a summary. The file holds all of
  // the call's output, the printed part too. Agent harnesses cut tool output
  // past about 30,000 characters (Claude Code keeps a 2,000-character
  // preview and a file; Codex keeps 10,000 tokens, head and tail), so the
  // default stays under both and the REPL decides what is kept.
  const DEFAULT_MAX_OUTPUT = 25000;
  // The most one call prints even when asked for no limit, so a call never
  // holds unbounded output in memory on its way to the caller.
  const HARD_MAX_OUTPUT = 4000000;
  const commas = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const spillCounters = new WeakMap();

  function createOutputGate(host, { maxOutput } = {}) {
    const asked = maxOutput === undefined || maxOutput === null ? DEFAULT_MAX_OUTPUT : maxOutput;
    const cap = asked > 0 && asked < HARD_MAX_OUTPUT ? asked : HARD_MAX_OUTPUT;
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
      // The session's own temporary directory (private, mode 0700).
      const dir = host.tmpdir;
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
        text = printable(text);
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
    let gate = null;
    // Everything the runtime prints goes through the current call's gate,
    // its own error reports (an event listener that threw) too. The native
    // session masks registered secrets in output, files and errors
    // (BrowserReplBoundary) and bounds what reaches it past the gate.
    const gatedPrint = (level, text) => (gate ? gate.print(level, text) : host.print(level, printable(text)));
    // A cancelled cell's leftover work (an await that resumes after its
    // timeout) is refused every host and driver call, so it acts neither
    // under a later cell nor between cells (createReplSession).
    let isCancelledWork = () => false;
    const cancelledError = (what) => {
      const e = new Error(`${what}: cancelled because the cell that started this work timed out; it does not run in a later cell`);
      e.code = "cancelled";
      return e;
    };
    const guarded = {};
    for (const name of ["setTimeout", "fsOp", "secrets", "policy"]) {
      if (typeof host[name] !== "function") continue;
      guarded[name] = {
        value: (...args) => {
          if (isCancelledWork()) throw cancelledError(name === "fsOp" ? "fs" : name);
          return host[name](...args);
        },
      };
    }
    if (typeof host.fetch === "function") {
      guarded.fetch = { value: (...args) => (isCancelledWork() ? Promise.reject(cancelledError("fetch")) : host.fetch(...args)) };
    }
    // The raw host and driver stay in this closure. Agent code reaches only
    // these frozen copies, whose prototype is Object.prototype, so a
    // cancelled cell cannot call a raw capability around the check
    // (Object.getPrototypeOf on a wrapper finds nothing callable).
    const ownSurface = (raw, overrides) => {
      const descriptors = {};
      for (const [name, d] of Object.entries(Object.getOwnPropertyDescriptors(raw))) {
        descriptors[name] = d.get ? { get: () => d.get.call(raw), enumerable: d.enumerable } : { value: d.value, enumerable: d.enumerable };
      }
      return Object.freeze(Object.defineProperties({}, { ...descriptors, ...overrides }));
    };
    const gatedHost = ownSurface(host, {
      print: { value: gatedPrint, enumerable: true },
      console: { value: Object.freeze({ error: (text) => gatedPrint("error", text) }), enumerable: true },
      ...guarded,
    });
    const guardedDriver = ownSurface(driver, {
      call: { value: (method, params) => (isCancelledWork() ? Promise.reject(cancelledError(method)) : driver.call(method, params)), enumerable: true },
    });
    const session = new core.Session({ driver: guardedDriver, host: gatedHost });
    const api = ns.api.createGlobals(session, gatedHost);
    const repl = createReplSession({ host: gatedHost, globals: [timerGlobals(gatedHost, api.importModule), api.globals] });
    isCancelledWork = repl.isCancelledWork;
    // A page listener belongs to the cell that registered it; a cancelled
    // cell's listeners are dropped instead of run.
    session.listenerOwnership = { owner: repl.ownerOnStack, isCancelled: repl.isCancelledCell };
    return {
      session,
      api,
      scope: repl.scope,
      async evaluate(code, { maxOutput, id } = {}) {
        const own = createOutputGate(host, { maxOutput });
        gate = own;
        try {
          const r = await repl.evaluate(code, { id });
          if (r.ok) {
            try {
              api.show(r.value);
            } catch (e) {
              return { ok: false, error: formatError(e), exception: e, ms: r.ms };
            }
          }
          return r;
        } finally {
          own.finish();
          if (gate === own) gate = null;
        }
      },
      cancel(message, id) {
        if (!repl.cancel(message, id)) return false;
        session._resetPendingState();
        return true;
      },
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
    // Agent code runs in this context. The native host stays in these
    // closures only: the global goes before any agent code runs, so a cell
    // cannot call it directly (the guards behind it are native anyway).
    delete root.__cmuxNative;
    const hostCall = (fn, op, args) => {
      const r = JSON.parse(fn(op, JSON.stringify(args || {})));
      if (r.error) {
        const e = new Error(r.error.message);
        e.code = r.error.code;
        throw e;
      }
      return r.ok;
    };
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
        // The app refuses a timer past its per-session bound
        // (scheduled timers plus fired ones whose callback has not run).
        if (native.setTimer(id, timerDelay(ms), false) === false) {
          throw new RangeError("setTimeout: this session has too many pending timers; clear some or let them run before adding more");
        }
        timers.set(id, fn);
        return id;
      },
      clearTimeout(id) {
        if (!timers.delete(id)) return;
        native.clearTimer(id);
      },
      now: () => Date.now(),
      print: (level, text) => native.print(level, printable(text)),
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
      secrets: (op, args) => hostCall(native.secrets, op, args),
      policy: (op, args) => hostCall(native.policy, op, args),
      async fetch(url, init) {
        const r = await callAsync((id) => native.fetch(id, JSON.stringify({
          url,
          method: init.method,
          headers: Object.entries(init.headers || {}),
          bodyBase64: init.body,
          targetId: init.targetId,
          credentials: init.credentials,
          origin: init.origin,
        })));
        return { url: r.url, status: r.status, statusText: r.statusText, headers: Object.fromEntries(r.headers || []), base64: r.bodyBase64 || "", redirected: r.redirected };
      },
    };
    host.console = Object.freeze({ error: (text) => native.print("error", printable(text)) });
    Object.freeze(host);
    const driver = {
      call: (method, params) => callAsync((id) => native.driverCall(id, method, JSON.stringify(params || {}))),
      on(event, handler) {
        if (!listeners.has(event)) listeners.set(event, new Set());
        listeners.get(event).add(handler);
        return () => listeners.get(event).delete(handler);
      },
      capabilities: () => native.capabilities || [],
    };
    Object.freeze(driver);
    let repl = null;
    // `optionsJSON` (optional): { "maxOutput": characters, 0 for no limit }.
    root.__cmuxReplEval = async (code, optionsJSON) => {
      if (!repl) repl = createBrowserRepl({ host, driver });
      const options = typeof optionsJSON === "string" && optionsJSON ? JSON.parse(optionsJSON) : {};
      const r = await repl.evaluate(code, { maxOutput: options.maxOutput, id: options.evalId });
      if (!r.ok) throw r.exception || new Error(r.error);
      return undefined;
    };
    // `timerIds`: the timers the app cancelled with the cell; their
    // callbacks go, so a fire already queued for one runs nothing.
    root.__cmuxReplCancel = (message, evalId, timerIds) => {
      for (const id of Array.isArray(timerIds) ? timerIds : []) timers.delete(id);
      return repl ? repl.cancel(message, evalId === null ? undefined : evalId) : false;
    };
    root.__cmuxFormatError = (e) => formatError(e);
    // The app takes these entry points and deletes the globals before any
    // cell runs, so a cell cannot call them (work they start would belong
    // to no cell). The runtime's namespace goes too: a cell must not build
    // a second REPL over this host and driver.
    delete root.CmuxBrowserRepl;
  }

  ns.replHost = { timerDelay, printable, rewriteTopLevel, createReplSession, createBrowserRepl, createOutputGate, DEFAULT_MAX_OUTPUT, HARD_MAX_OUTPUT, formatError, installNativeHost };
  installNativeHost();
})(typeof globalThis !== "undefined" ? globalThis : this);
