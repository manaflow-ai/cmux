// Which REPL cell owns the code running now, on an engine whose Error
// stacks do not name a resumed async function's callers.
//
// repl-host.js refuses a timed-out cell's leftover work (an await that
// resumes after its cell timed out) every host and driver call. It finds
// the owner on the stack: each cell body runs as a function named
// __cmuxCell<seq>, and an engine with async stack traces names it under
// every async function the cell awaits, also inside the runtime's own
// async functions (tabs.list awaits before it calls the driver). Before
// macOS 27, JavaScriptCore records no async stack trace (its
// `useAsyncStackTrace` option is off and frozen once the app's first
// JavaScript context exists), so a cell's async function that resumes late
// shows only itself and the refusal never fired.
//
// There the owner is carried explicitly. Every async function in the
// runtime's scripts and in each cell's code is rewritten (acorn, at load or
// before the cell runs) so that it takes the owner of the code that called
// it when it starts, makes it the current owner again whenever it resumes
// (after an `await`, a `yield`, a `for await` step, or into a `catch` or
// `finally` a rejection resumed), and gives the previous owner back when it
// suspends or returns. The rewrite only inserts text; a function's
// toString() gives its source as written (what a page receives when a
// function is passed to page.evaluate).
//
// Like the stack, this keeps a cell's own stale work from acting late; it
// is not a guard against code that means to get around it (agent code can
// call the tracker), and a `.then()` callback runs as the owner of no cell,
// as it does on an engine with async stacks.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  const StackError = Error;
  const nativeToString = Function.prototype.toString;

  // The owner (a cell object) of the code running now, or undefined.
  let current;
  // A token per async function call: the owner it took when it started,
  // and, while it runs resumed, the owner to give back when it suspends.
  const tracker = Object.freeze({
    owner: () => current,
    // Native entry points (a timer, a driver result, an event, a new
    // cell) start as no cell's code.
    reset() {
      current = undefined;
    },
    enter: () => ({ owner: current, active: false, saved: undefined }),
    begin(owner) {
      const token = { owner, active: true, saved: current };
      current = owner;
      return token;
    },
    back(token, value) {
      if (!token.active) {
        token.saved = current;
        token.active = true;
      }
      current = token.owner;
      return value;
    },
    leave(token, value) {
      if (token.active) {
        current = token.saved;
        token.saved = undefined;
        token.active = false;
      }
      return value;
    },
    // A `for await` loop's iterator: each step it asks for gives the
    // owner back before the loop suspends on it.
    iter(token, iterable) {
      return {
        [Symbol.asyncIterator]() {
          const method = iterable == null ? undefined : iterable[Symbol.asyncIterator];
          const inner = method != null ? method.call(iterable) : (async function* () {
            yield* iterable;
          })();
          // The step starts as the loop's code (an async generator's body
          // takes its owner), then the loop suspends on it.
          const step = (name) => (...args) => {
            const fn = inner[name];
            let result;
            if (typeof fn === "function") result = fn.apply(inner, args);
            else result = name === "return" ? Promise.resolve({ done: true, value: args[0] }) : Promise.reject(args[0]);
            tracker.leave(token);
            return result;
          };
          return { next: step("next"), return: step("return"), throw: step("throw") };
        },
      };
    },
  });

  // The texts the rewrite inserts. Each names __cmuxT, so a function's
  // source as written is its rewritten source with every one removed.
  const T = {
    bodyOpen: ";const __cmuxK=__cmuxT.enter();try{",
    bodyClose: "}finally{__cmuxT.leave(__cmuxK)}",
    arrowOpen: "{const __cmuxK=__cmuxT.enter();try{return(/*__cmuxT*/",
    arrowClose: "/*__cmuxT*/)}finally{__cmuxT.leave(__cmuxK)}}",
    back: "__cmuxT.back(__cmuxK,",
    leave: "__cmuxT.leave(__cmuxK,",
    leaveBare: " __cmuxT.leave(__cmuxK)",
    close: "/*__cmuxT*/)",
    resumed: "__cmuxT.back(__cmuxK);",
    iter: "__cmuxT.iter(__cmuxK,",
    loopBodyOpen: "{/*__cmuxT*/__cmuxT.back(__cmuxK);",
    blockClose: "/*__cmuxT*/}",
    loopOpen: "{/*__cmuxT*/",
    loopClose: ";__cmuxT.back(__cmuxK)/*__cmuxT*/}",
  };
  const INSERTED = new RegExp(
    Object.values(T)
      .sort((a, b) => b.length - a.length)
      .map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
      .join("|"),
    "g",
  );
  const asWritten = (source) => (source.includes("__cmuxT") ? source.replace(INSERTED, "") : source);

  function acornApi() {
    const acorn = root.acorn || (ns.vendor && ns.vendor.acorn);
    if (!acorn) throw new Error("acorn is not loaded");
    return acorn;
  }

  const isFunction = (node) => node.type === "FunctionDeclaration" || node.type === "FunctionExpression" || node.type === "ArrowFunctionExpression";

  // Rewrites `code` (a script, or a cell's body when `cell`: its top level
  // then belongs to the cell's own token, which the caller declares).
  function instrument(code, { cell = false } = {}) {
    const ast = acornApi().parse(code, {
      ecmaVersion: "latest",
      sourceType: "script",
      allowAwaitOutsideFunction: cell,
      allowReturnOutsideFunction: false,
      allowHashBang: true,
      preserveParens: true,
    });
    const edits = [];
    const add = (pos, text, open, depth) => edits.push({ pos, text, open, depth });
    // `owner`: whether the innermost function (or the cell's top level)
    // is async, so its awaits, catches and loops carry its token.
    function visit(node, depth, owned, labels) {
      if (!node || typeof node.type !== "string") return;
      let inner = owned;
      if (isFunction(node)) {
        inner = !!node.async;
        if (node.async) {
          const body = node.body;
          if (body.type === "BlockStatement") {
            let at = body.start + 1;
            for (const stmt of body.body) {
              if (stmt.type !== "ExpressionStatement" || typeof stmt.directive !== "string") break;
              at = stmt.end;
            }
            // An empty body takes both at one position, in order.
            if (at === body.end - 1) add(at, T.bodyOpen + T.bodyClose, true, depth + 0.5);
            else {
              add(at, T.bodyOpen, true, depth + 0.5);
              add(body.end - 1, T.bodyClose, false, depth + 0.5);
            }
          } else {
            add(body.start, T.arrowOpen, true, depth + 0.5);
            add(body.end, T.arrowClose, false, depth + 0.5);
          }
        }
      } else if (owned) {
        if (node.type === "AwaitExpression") {
          add(node.start, T.back, true, depth);
          add(node.argument.start, T.leave, true, depth + 0.5);
          add(node.argument.end, T.close, false, depth + 0.5);
          add(node.end, T.close, false, depth);
        } else if (node.type === "YieldExpression") {
          add(node.start, T.back, true, depth);
          if (node.argument) {
            add(node.argument.start, T.leave, true, depth + 0.5);
            add(node.argument.end, T.close, false, depth + 0.5);
            add(node.end, T.close, false, depth);
          } else {
            // A bare `yield` ends where its argument would go.
            add(node.end, T.leaveBare + T.close, false, depth);
          }
        } else if (node.type === "CatchClause") {
          add(node.body.start + 1, T.resumed, true, depth + 0.5);
        } else if (node.type === "TryStatement" && node.finalizer) {
          add(node.finalizer.start + 1, T.resumed, true, depth + 0.5);
        } else if (node.type === "ForOfStatement" && node.await) {
          const start = labels.length ? labels[0].start : node.start;
          add(start, T.loopOpen, true, depth - labels.length - 0.5);
          add(node.end, T.loopClose, false, depth - labels.length - 0.5);
          add(node.right.start, T.iter, true, depth + 0.5);
          add(node.right.end, T.close, false, depth + 0.5);
          add(node.body.start, T.loopBodyOpen, true, depth + 0.5);
          add(node.body.end, T.blockClose, false, depth + 0.5);
        }
      }
      const nextLabels = node.type === "LabeledStatement" ? [...labels, node] : [];
      for (const key of Object.keys(node)) {
        if (key === "type" || key === "start" || key === "end" || key === "loc" || key === "range") continue;
        const value = node[key];
        if (Array.isArray(value)) {
          for (const child of value) visit(child, depth + 1, inner, []);
        } else if (value && typeof value === "object" && typeof value.type === "string") {
          visit(value, depth + 1, inner, key === "body" && node.type === "LabeledStatement" ? nextLabels : []);
        }
      }
    }
    visit(ast, 0, cell, []);
    if (!edits.length) return code;
    // At one position, closes go first (innermost first), then opens
    // (outermost first), so the inserted parts nest as their nodes do.
    edits.sort((a, b) => a.pos - b.pos || (a.open === b.open ? (a.open ? a.depth - b.depth : b.depth - a.depth) : a.open ? 1 : -1));
    let out = "";
    let cursor = 0;
    for (const edit of edits) {
      out += code.slice(cursor, edit.pos) + edit.text;
      cursor = edit.pos;
    }
    return out + code.slice(cursor);
  }

  // Whether this engine's stacks name the async callers of a resumed
  // async function. Known once the probe's promise jobs ran (JavaScriptCore
  // runs them when the script that loads this file returns); until then,
  // and where it does, nothing is rewritten.
  let needed = false;
  let toStringInstalled = false;
  (async function __cmuxAsyncOwnerProbe() {
    await (async () => {
      await null;
      needed = !/__cmuxAsyncOwnerProbe/.test(String(new StackError().stack || ""));
    })();
  })();

  // A function's source as written, also for a rewritten one.
  function installToString() {
    if (toStringInstalled) return;
    toStringInstalled = true;
    const toString = {
      toString() {
        return asWritten(nativeToString.call(this));
      },
    }.toString;
    Object.defineProperty(Function.prototype, "toString", { value: toString, writable: true, configurable: true, enumerable: false });
  }

  ns.asyncOwner = {
    tracker,
    instrument,
    asWritten,
    get active() {
      return needed;
    },
    // A runtime script, rewritten when this engine needs it; it then runs
    // with `__cmuxT` bound to the tracker.
    prepareScript(source) {
      if (!needed) return source;
      installToString();
      return `(function (__cmuxT) {${instrument(source)}\n}).call(this, CmuxBrowserRepl.asyncOwner.tracker);`;
    },
    // A cell's body, rewritten when this engine needs it (its top level
    // then uses the token the cell's function declares), else as given.
    prepareCell(code) {
      if (!needed) return { source: code, instrumented: false };
      installToString();
      return { source: instrument(code, { cell: true }), instrumented: true };
    },
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
