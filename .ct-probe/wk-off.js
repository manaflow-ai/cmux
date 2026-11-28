(() => { const s = document.createElement("style"); s.textContent = "html .acpmux-spacer > .acpmux-thread{will-change:auto}"; (document.head||document.documentElement).appendChild(s); })();
// WebKit cost probe for composer-typing.bench.ts --probe: time spent per JS entry point and per forced layout,
// named by source line, plus rAF frame gaps split into JS and non-JS time.
(() => {
  const now = () => performance.now();
  const site = (skip) => {
    const lines = (new Error().stack || "").split("\n").slice(skip);
    for (const line of lines) {
      if (line.includes("wk-cost-probe") || line.includes("__probe")) continue;
      const m = line.match(/(?:at\s+)?([^@\s(]*)@?\(?(.*?):(\d+):\d+\)?$/);
      if (m) return `${m[1] || "anon"} ${m[2].replace(/^.*\/(src|node_modules)\//, "$1/")}:${m[3]}`;
    }
    return "?";
  };
  let curKey = null;
  let skipped = 0;
  const SKIP = window.__skipAnim || "";
  const animate = Element.prototype.animate;
  Element.prototype.animate = function (frames, opts) {
    const first = Array.isArray(frames) ? frames[0] : frames;
    const isRows = first && "translate" in first && opts && opts.composite === "add";
    const isField = first && "height" in first && this.classList?.contains("acpmux-md-field");
    if ((SKIP === "rows" && isRows) || (SKIP === "field" && isField)) {
      skipped += 1;
      return animate.call(this, frames, { ...opts, duration: 0 });
    }
    return animate.call(this, frames, opts);
  };
  const js = new Map();
  const layout = new Map();
  let depth = 0;
  let jsInFrame = 0;
  let jsTotal = 0;
  const add = (map, key, ms) => {
    const e = map.get(key) || { n: 0, ms: 0, max: 0 };
    e.n += 1;
    e.ms += ms;
    if (ms > e.max) e.max = ms;
    map.set(key, e);
  };
  const wrap = (kind, fn, label) => {
    if (typeof fn !== "function") return fn;
    return function (...args) {
      if (depth > 0) return fn.apply(this, args);
      depth += 1;
      const t = now();
      try {
        return fn.apply(this, args);
      } finally {
        const ms = now() - t;
        depth -= 1;
        jsInFrame += ms;
        jsTotal += ms;
        add(js, `${kind} ${label}`, ms);
        if (ms > 2 && curKey) curKey.big.push(`${kind} ${label.split(" ")[0]} ${ms.toFixed(0)}`);
      }
    };
  };
  const g = window;
  const raf = g.requestAnimationFrame.bind(g);
  g.requestAnimationFrame = (cb) => raf(wrap("raf", cb, site(2)));
  for (const name of ["setTimeout", "setInterval", "queueMicrotask"]) {
    const orig = g[name].bind(g);
    g[name] = (cb, ...rest) => orig(wrap(name, cb, site(2)), ...rest);
  }
  for (const Ctor of ["ResizeObserver", "MutationObserver", "IntersectionObserver"]) {
    const Orig = g[Ctor];
    if (!Orig) continue;
    g[Ctor] = class extends Orig {
      constructor(cb, opts) {
        super(wrap(Ctor, cb, site(2)), opts);
      }
    };
  }
  const addEv = EventTarget.prototype.addEventListener;
  const handlers = new WeakMap();
  EventTarget.prototype.addEventListener = function (type, cb, opts) {
    if (typeof cb !== "function") return addEv.call(this, type, cb, opts);
    let w = handlers.get(cb);
    if (!w) {
      w = wrap(`ev:${type}`, cb, site(2));
      handlers.set(cb, w);
    }
    return addEv.call(this, type, w, opts);
  };
  const remEv = EventTarget.prototype.removeEventListener;
  EventTarget.prototype.removeEventListener = function (type, cb, opts) {
    return remEv.call(this, type, (typeof cb === "function" && handlers.get(cb)) || cb, opts);
  };
  // Forced layout: time the reads; name the site only for slow ones (a stack per read costs).
  const timeRead = (proto, name, isGetter) => {
    const d = Object.getOwnPropertyDescriptor(proto, name);
    if (!d) return;
    const orig = isGetter ? d.get : d.value;
    if (typeof orig !== "function") return;
    const timed = function (...args) {
      const t = now();
      const r = orig.apply(this, args);
      const ms = now() - t;
      if (ms > 0.3) { const where = site(2); add(layout, `${name} ${where}`, ms); if (ms > 2 && curKey) curKey.big.push(`L:${name} ${where.split(" ")[0]} ${ms.toFixed(0)}`); }
      else add(layout, `${name} (fast)`, ms);
      return r;
    };
    Object.defineProperty(proto, name, isGetter ? { ...d, get: timed } : { ...d, value: timed });
  };
  for (const n of ["getBoundingClientRect", "getClientRects"]) timeRead(Element.prototype, n, false);
  for (const n of ["scrollHeight", "scrollWidth", "clientHeight", "clientWidth", "scrollTop"]) timeRead(Element.prototype, n, true);
  for (const n of ["offsetHeight", "offsetWidth", "offsetTop", "offsetLeft"]) timeRead(HTMLElement.prototype, n, true);
  timeRead(window, "getComputedStyle", false);
  // Frame gaps: a self-scheduled rAF loop; each gap's JS (wrapped entry points) vs the rest.
  const gaps = [];
  let last = 0;
  const loop = (ts) => {
    const t = now();
    if (last) gaps.push([t - last, jsInFrame]);
    last = t;
    jsInFrame = 0;
    raf(loop);
  };
  raf(loop);
  // Per key: keydown time, the next rAF after it, the JS run in between, the input's height and scroller height.
  const keys = [];
  addEv.call(window, "keydown", (e) => {
    const k = { i: keys.length, t: now(), key: e.key, js0: jsTotal, big: [], grew: false };
    keys.push(k); curKey = k;
    raf(() => { k.raf = now() - k.t; k.js = jsTotal - k.js0; setTimeout(() => { k.late = now() - k.t; }, 0); });
  }, true);
  addEv.call(document, "acpmux-field-growth", () => { if (curKey) curKey.grew = true; }, true);
  const started = now();
  g.__probe = () => {
    const top = (map, k) =>
      [...map.entries()]
        .sort((a, b) => b[1].ms - a[1].ms)
        .slice(0, k)
        .map(([key, e]) => `${e.ms.toFixed(0)}ms n${e.n} max${e.max.toFixed(1)} ${key}`);
    const sorted = gaps.map((x) => x[0]).sort((a, b) => a - b);
    const q = (p) => sorted[Math.floor(p * (sorted.length - 1))]?.toFixed(1);
    const slow = gaps.filter((x) => x[0] > 33);
    const slowGap = slow.reduce((s, x) => s + x[0], 0);
    const slowJs = slow.reduce((s, x) => s + x[1], 0);
    return {
      elapsed_ms: Math.round(now() - started),
      js_total_ms: Math.round(jsTotal),
      frames: gaps.length,
      gap_p50: q(0.5),
      gap_p95: q(0.95),
      slow_frames: slow.length,
      slow_gap_ms: Math.round(slowGap),
      slow_js_ms: Math.round(slowJs),
      slow_keys: keys.filter((k) => k.raf > 30).map((k) => `#${k.i} ${k.key} t${Math.round(k.t - started)} raf${k.raf.toFixed(0)} js${k.js.toFixed(1)}${k.grew ? " GREW" : ""} ${k.big.slice(0, 8).join("; ")}`),
      grew_keys: keys.filter((k) => k.grew).map((k) => `#${k.i} raf${k.raf?.toFixed(0)} next[${keys.slice(k.i + 1, k.i + 6).map((n) => n.raf?.toFixed(0)).join(",")}]`),
      skipped: skipped,
      slow_gaps: gaps.map((x, i) => [i, x[0], x[1]]).filter((x) => x[1] > 33).slice(0, 60).map((x) => `f${x[0]} ${x[1].toFixed(0)} js${x[2].toFixed(1)}`),
      js: top(js, 25),
      layout: top(layout, 25),
    };
  };
})();
