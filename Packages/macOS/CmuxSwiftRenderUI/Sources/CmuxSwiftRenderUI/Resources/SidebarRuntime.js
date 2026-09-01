"use strict";
// cmux sidebar JS runtime prelude.
//
// A fine-grained reactive scene runtime, SolidJS-shaped: the sidebar program
// runs ONCE, builds a retained scene graph, and subscribes to host data via
// signals. Data changes re-run only the effects that read them, emitting
// minimal scene ops (single-prop updates, keyed child reconciles) that the
// host applies to @Observable scene nodes. Nothing re-renders per tick.
//
// Host bridge (injected by SidebarJSRuntime.swift before this file runs):
//   __host_applyOps(jsonString)  - apply a batch of scene ops
//   __host_action(jsonString)    - run captured commands (cmux/openURL/log)
//   __host_log(string)           - debug logging
// Host entry points (defined here, called by Swift):
//   __setData(key, jsonString)   - update one data key
//   __dispatch(nodeId, event, jsonString) - deliver a UI event
//   __mount(fn)                  - internal: run the sidebar program

(function () {
  // ---------------------------------------------------------------------
  // Reactive core
  // ---------------------------------------------------------------------
  let currentEffect = null;
  let currentScope = null;
  const pendingEffects = new Set();
  let running = false;

  function createSignal(initial) {
    let value = initial;
    const subscribers = new Set();
    const read = () => {
      if (currentEffect) {
        subscribers.add(currentEffect);
        currentEffect.deps.push(subscribers);
      }
      return value;
    };
    const write = (next) => {
      if (Object.is(value, next)) return;
      value = next;
      for (const eff of Array.from(subscribers)) pendingEffects.add(eff);
      scheduleRun();
    };
    return [read, write];
  }

  function createEffect(fn) {
    const eff = {
      deps: [],
      disposed: false,
      run() {
        if (eff.disposed) return;
        cleanupDeps(eff);
        const prevEffect = currentEffect;
        currentEffect = eff;
        try {
          fn();
        } finally {
          currentEffect = prevEffect;
        }
      },
    };
    if (currentScope) currentScope.effects.push(eff);
    eff.run();
    return eff;
  }

  function cleanupDeps(eff) {
    for (const subscribers of eff.deps) subscribers.delete(eff);
    eff.deps = [];
  }

  function scheduleRun() {
    if (running) return; // drained by the active runPending pass
    runPending();
  }

  function runPending() {
    running = true;
    try {
      let guard = 0;
      while (pendingEffects.size > 0) {
        if (++guard > 1000) {
          throw new Error("sidebar effect loop did not settle (1000 rounds)");
        }
        const batch = Array.from(pendingEffects);
        pendingEffects.clear();
        for (const eff of batch) eff.run();
      }
    } finally {
      running = false;
      flushOps();
    }
  }

  // Scopes own effects and child nodes for disposal (row unmount).
  function createScope(parent) {
    return { effects: [], nodes: [], children: [], parent };
  }

  function runInScope(scope, fn) {
    const prev = currentScope;
    if (prev) {
      prev.children.push(scope);
      scope.parent = prev;
    }
    currentScope = scope;
    try {
      return fn();
    } finally {
      currentScope = prev;
    }
  }

  function disposeScope(scope) {
    // Detach from the parent, or a churning keyed list retains every
    // unmounted row scope in the long-lived owner forever.
    if (scope.parent) {
      const siblings = scope.parent.children;
      const at = siblings.indexOf(scope);
      if (at >= 0) siblings.splice(at, 1);
      scope.parent = null;
    }
    for (const child of scope.children) {
      child.parent = null; // already being disposed with us; skip the splice
      disposeScope(child);
    }
    scope.children = [];
    for (const eff of scope.effects) {
      eff.disposed = true;
      cleanupDeps(eff);
      pendingEffects.delete(eff);
    }
    scope.effects = [];
    for (const id of scope.nodes) {
      delete handlers[id];
      pushOp({ op: "remove", id });
    }
    scope.nodes = [];
  }

  // ---------------------------------------------------------------------
  // Scene ops
  // ---------------------------------------------------------------------
  let nextId = 1;
  let ops = [];
  const handlers = Object.create(null);

  function pushOp(op) {
    ops.push(op);
  }

  function flushOps() {
    if (ops.length === 0) return;
    const batch = ops;
    ops = [];
    __host_applyOps(JSON.stringify(batch));
  }

  // ---------------------------------------------------------------------
  // Node handles and builders
  // ---------------------------------------------------------------------
  // Reactive prop: a function-valued prop re-evaluates in its own effect and
  // emits a single-prop update op when its value changes.
  function setProp(id, key, value) {
    if (typeof value === "function") {
      createEffect(() => {
        pushOp({ op: "update", id, key, value: normalizeProp(value()) });
      });
    } else {
      pushOp({ op: "update", id, key, value: normalizeProp(value) });
    }
  }

  function normalizeProp(v) {
    if (v === null || v === undefined) return null;
    const t = typeof v;
    if (t === "string" || t === "boolean") return v;
    if (t === "number") return Number.isFinite(v) ? v : null;
    return String(v);
  }

  const chainableProps = [
    "font", "color", "padding", "background", "cornerRadius", "opacity",
    "bold", "italic", "monospaced", "lineLimit", "spacing", "size",
    "width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight",
    "alignment", "fill", "stroke", "strokeWidth", "systemName", "value",
    "help", "truncation", "weight", "secondary", "borderColor", "borderWidth",
    "hoverBackground", "paddingHorizontal", "paddingVertical", "destructive",
    "paddingLeading", "paddingTrailing", "paddingTop", "paddingBottom",
    "fixed", "block", "layoutPriority", "marginLeading",
    "showOnHover", "hideOnHover", "dragBackground", "dragSet", "rotation",
    "fade", "marquee",
  ];

  function makeHandle(id) {
    const handle = { __nodeId: id };
    for (const key of chainableProps) {
      handle[key] = (value) => {
        // Bare `.bold()` / `.secondary()` style toggles default to true.
        setProp(id, key, value === undefined ? true : value);
        return handle;
      };
    }
    handle.frame = (spec) => {
      for (const k of Object.keys(spec || {})) setProp(id, k, spec[k]);
      return handle;
    };
    handle.onTap = (fn) => {
      handlers[id] = handlers[id] || {};
      handlers[id].tap = fn;
      setProp(id, "tappable", true);
      return handle;
    };
    // Double-click (e.g. rename affordance). Coexists with onTap: the host
    // registers the two-click recognizer first, so a double fires this and
    // not two taps.
    handle.onDoubleTap = (fn) => {
      handlers[id] = handlers[id] || {};
      handlers[id].doubletap = fn;
      setProp(id, "doubleTappable", true);
      return handle;
    };
    // Right-click menu: the items (Button / Menu / Divider / Text) become a
    // contextMenu child node; the host renders it as the view's context menu
    // instead of inline content.
    handle.contextMenu = (children) => {
      const menu = makeNode("contextMenu", {}, children);
      pushOp({ op: "append", id, child: menu.__nodeId });
      return handle;
    };
    return handle;
  }

  function applyProps(id, props) {
    for (const key of Object.keys(props || {})) {
      const value = props[key];
      if (key === "onTap" || key === "onMove") {
        handlers[id] = handlers[id] || {};
        handlers[id][key === "onTap" ? "tap" : "move"] = value;
        if (key === "onTap") setProp(id, "tappable", true);
        continue;
      }
      setProp(id, key, value);
    }
  }

  function childIds(children) {
    const out = [];
    for (const child of flatten(children)) {
      if (child && child.__nodeId) out.push(child.__nodeId);
    }
    return out;
  }

  function flatten(children) {
    if (!children) return [];
    if (!Array.isArray(children)) return [children];
    const out = [];
    for (const c of children) {
      if (Array.isArray(c)) out.push(...flatten(c));
      else out.push(c);
    }
    return out;
  }

  function makeNode(type, props, children) {
    const id = "n" + nextId++;
    if (currentScope) currentScope.nodes.push(id);
    pushOp({ op: "create", id, type });
    applyProps(id, props);
    if (children !== undefined) {
      pushOp({ op: "children", id, children: childIds(children) });
    }
    return makeHandle(id);
  }

  // Container builders accept (props, children) or just (children).
  function container(type) {
    return (a, b) => {
      if (Array.isArray(a) || (a && a.__nodeId)) return makeNode(type, {}, a);
      return makeNode(type, a || {}, b || []);
    };
  }

  const g = globalThis;
  g.VStack = container("vstack");
  g.HStack = container("hstack");
  g.ZStack = container("zstack");
  g.LazyVStack = container("lazyVStack");
  g.Group = container("group");

  g.Text = (text, props) => {
    const node = makeNode("text", props || {});
    setProp(node.__nodeId, "text", text);
    return node;
  };
  g.Image = (systemName, props) => makeNode("image", { systemName, ...(props || {}) });
  g.Spacer = (props) => makeNode("spacer", props || {});
  g.Divider = (props) => makeNode("divider", props || {});
  g.Circle = (props) => makeNode("circle", props || {});
  g.Capsule = (props) => makeNode("capsule", props || {});
  g.Rectangle = (props) => makeNode("rectangle", props || {});
  g.RoundedRectangle = (props) => makeNode("roundedRectangle", props || {});
  g.ProgressView = (props) => makeNode("progress", props || {});

  // Submenu inside a context menu (or a standalone menu button).
  g.Menu = (title, children) => {
    const node = makeNode("menu", {}, children);
    setProp(node.__nodeId, "text", title);
    return node;
  };

  // Editable one-line text field. `value` is the initial text (string or
  // binding); opts: placeholder, onSubmit(text), onCancel(), onEdit(text)
  // (fires per keystroke - live search), autofocus (default true; pass
  // false for persistent fields so mounting never steals focus). The host
  // focuses autofocus fields on appear; Return submits, Escape cancels.
  g.TextField = (value, opts) => {
    const node = makeNode("textfield", {});
    setProp(node.__nodeId, "text", value);
    if (opts && opts.placeholder) setProp(node.__nodeId, "placeholder", opts.placeholder);
    if (opts && opts.autofocus === false) setProp(node.__nodeId, "autofocus", false);
    handlers[node.__nodeId] = handlers[node.__nodeId] || {};
    if (opts && opts.onSubmit) handlers[node.__nodeId].submit = opts.onSubmit;
    if (opts && opts.onCancel) handlers[node.__nodeId].cancel = opts.onCancel;
    if (opts && opts.onEdit) handlers[node.__nodeId].edit = opts.onEdit;
    return node;
  };

  g.Button = (label, action, children) => {
    const node = makeNode("button", {}, children);
    if (typeof label === "string" || typeof label === "function") {
      setProp(node.__nodeId, "text", label);
    }
    if (typeof action === "function") {
      handlers[node.__nodeId] = handlers[node.__nodeId] || {};
      handlers[node.__nodeId].tap = action;
    }
    return node;
  };

  // ---------------------------------------------------------------------
  // Keyed list reconciliation (ForEach / Reorderable)
  // ---------------------------------------------------------------------
  // items: array or accessor; key: (item) => string; template: (itemAccessor,
  // keyString) => handle. Rows mount once per key; kept rows get their item
  // signal updated (value-compared, so unchanged rows do nothing); removed
  // rows dispose their scope (effects + nodes).
  function keyedList(type, opts, template) {
    const items = opts.items;
    const keyFn = opts.key || ((item) => String(item && item.id !== undefined ? item.id : item));
    // Scalar options (e.g. spacing) become node props; the wiring keys are not.
    const props = {};
    for (const k of Object.keys(opts)) {
      if (k !== "items" && k !== "key" && k !== "onMove") props[k] = opts[k];
    }
    const node = makeNode(type, props, []);
    const id = node.__nodeId;
    if (opts.onMove) {
      handlers[id] = handlers[id] || {};
      handlers[id].move = opts.onMove;
    }
    const rows = new Map(); // key -> {scope, rootId, setItem, serialized}
    const owner = currentScope;

    createEffect(() => {
      const list = typeof items === "function" ? items() : items;
      const arr = Array.isArray(list) ? list : [];
      const seen = new Set();
      const order = [];
      const orderedKeys = [];
      for (const item of arr) {
        const key = String(keyFn(item));
        if (seen.has(key)) continue; // ignore duplicate keys
        seen.add(key);
        let row = rows.get(key);
        const serialized = JSON.stringify(item);
        if (!row) {
          const scope = createScope(owner);
          const [readItem, writeItem] = createSignal(item);
          const handle = runInScope(scope, () => template(readItem, key));
          row = { scope, rootId: handle ? handle.__nodeId : null, setItem: writeItem, serialized };
          rows.set(key, row);
        } else if (row.serialized !== serialized) {
          row.serialized = serialized;
          row.setItem(item);
        }
        if (row.rootId) {
          order.push(row.rootId);
          orderedKeys.push(key);
        }
      }
      for (const [key, row] of Array.from(rows.entries())) {
        if (!seen.has(key)) {
          disposeScope(row.scope);
          rows.delete(key);
        }
      }
      pushOp({ op: "children", id, children: order });
      // Reorderable rows carry their item keys (JSON array, parallel to
      // children) so the host can report moves by item id. Keys were
      // collected during the reconcile loop; no second scan.
      if (type === "reorderable") {
        pushOp({ op: "update", id, key: "itemKeys", value: JSON.stringify(orderedKeys) });
      }
    });
    return node;
  }

  g.ForEach = (opts, template) => keyedList("group", opts, template);
  g.Reorderable = (opts, template) => keyedList("reorderable", opts, template);

  // ---------------------------------------------------------------------
  // Host data and actions
  // ---------------------------------------------------------------------
  const dataSignals = new Map(); // key -> [read, write]

  function dataSignal(key) {
    let sig = dataSignals.get(key);
    if (!sig) {
      sig = createSignal(undefined);
      dataSignals.set(key, sig);
    }
    return sig;
  }

  g.data = new Proxy({}, {
    get(_t, key) {
      if (typeof key !== "string") return undefined;
      return () => dataSignal(key)[0]();
    },
  });

  // Author-facing reactive state: `const [open, setOpen] = signal(false)`.
  // Reads inside any function-valued prop subscribe it; writes re-run exactly
  // the bindings that read it.
  g.signal = (initial) => createSignal(initial);
  g.computed = (fn) => {
    const [read, write] = createSignal(undefined);
    createEffect(() => write(fn()));
    return read;
  };

  g.cmux = (method, params) => {
    const p = {};
    for (const k of Object.keys(params || {})) p[k] = String(params[k]);
    __host_action(JSON.stringify({ kind: "cmux", method, params: p }));
  };
  g.openURL = (url) => __host_action(JSON.stringify({ kind: "openURL", url: String(url) }));
  g.log = (message) => __host_action(JSON.stringify({ kind: "log", message: String(message) }));

  // ---------------------------------------------------------------------
  // Host entry points
  // ---------------------------------------------------------------------
  g.__setData = (key, json) => {
    dataSignal(key)[1](JSON.parse(json));
    runPending();
  };

  g.__dispatch = (nodeId, event, json) => {
    const nodeHandlers = handlers[nodeId];
    if (!nodeHandlers) return;
    const payload = json ? JSON.parse(json) : null;
    if (event === "tap" && nodeHandlers.tap) nodeHandlers.tap(payload);
    if (event === "move" && nodeHandlers.move) nodeHandlers.move(payload.id, payload.index, payload);
    if (event === "doubletap" && nodeHandlers.doubletap) nodeHandlers.doubletap(payload);
    if (event === "submit" && nodeHandlers.submit) nodeHandlers.submit(payload ? payload.text : "");
    if (event === "cancel" && nodeHandlers.cancel) nodeHandlers.cancel(payload);
    if (event === "edit" && nodeHandlers.edit) nodeHandlers.edit(payload ? payload.text : "");
    runPending();
  };

  // Optional second argument: surface options applied as root props.
  // `surface: "glass"` asks the host to render the whole sidebar surface as
  // translucent material (liquid glass) instead of its opaque backdrop.
  g.sidebar = (fn, opts) => {
    const rootScope = createScope(null);
    const handle = runInScope(rootScope, fn);
    if (!handle || !handle.__nodeId) {
      throw new Error("sidebar(fn) must return a view (e.g. VStack([...]))");
    }
    if (opts) applyProps(handle.__nodeId, opts);
    pushOp({ op: "root", id: handle.__nodeId });
    runPending();
  };
})();
