// cmux browser REPL snapshot: stitches each frame's tree from the page agent
// into one accessibility snapshot, renders it as text, and diffs it against
// the previous snapshot of the same tab. Format: docs/browser-repl/README.md.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  const core = ns.core;

  const CELL_ROLES = new Set(["cell", "gridcell", "columnheader", "rowheader"]);
  // Roles that say something even with no name, value or children.
  const MEANINGFUL_EMPTY_ROLES = new Set(["separator", "iframe", "img", "image", "canvas", "progressbar", "meter", "slider",
    "scrollbar", "math"]);
  // A name from content longer than this prints as its content instead.
  const CONTENT_NAME_LIMIT = 200;
  // Longest name printed, other than a name that stands for the content;
  // longer names end in "…" (refs still resolve).
  const NAME_LIMIT = 100;
  // Longest URL printed without { urls: true }.
  const URL_LIMIT = 100;
  // Unnamed wrappers that print as their only element child.
  const TRANSPARENT_WRAPPERS = new Set(["listitem", "cell", "gridcell"]);
  // Printing prefers the diff whenever it is shorter than the tree; above
  // this tree size it must also be at least DIFF_SAVING smaller, because a
  // long diff that is nearly the whole page reads worse than the page.
  const DIFF_FLOOR = 2048;
  const DIFF_SAVING = 0.3;
  // Collapsed <select> options printed inline before "+N more".
  const INLINE_OPTIONS = 10;
  // Text of one to three punctuation characters ("|", "(", "·") says nothing
  // on its own line.
  const PUNCTUATION = /^[\p{P}|]{1,3}$/u;
  // Context kept in interactive mode: the page outline.
  const LANDMARK_ROLES = new Set(["banner", "main", "navigation", "contentinfo", "complementary", "search", "form", "region",
    "dialog", "alertdialog"]);

  const q = (s) => JSON.stringify(String(s));
  const normalize = (s) => String(s || "").replace(/\s+/g, " ").trim();
  // Engines join inline content with or without spaces, and pages pad text
  // with zero-width characters; compare without either.
  // Case does not count either ("Main content" repeats "main content").
  const squash = (s) => String(s || "").replace(/[\s\u200b-\u200d\u2060\ufeff]+/g, "").toLowerCase();

  function hasRef(list) {
    return (list || []).some((c) => typeof c !== "string" && (c.ref || hasRef(c.children)));
  }

  // Text a node contributes to its parent's name: its own name, else its text.
  function textOf(list) {
    return normalize((list || []).map((c) => (typeof c === "string" ? c : c.name || c.value || textOf(c.children))).join(" "));
  }

  // ---------------------------------------------------------------------------
  // Tree shaping (host side, engine-neutral)

  // Punctuation-only text between two texts joins them ("a | b"); next to an
  // element it is dropped, and so are punctuation tokens at the edge of a
  // text that borders an element.
  function foldPunctuation(input) {
    // Punctuation tokens at the edge of a text that borders an element
    // (") 10 points by" after a link) go too.
    const list = input.map((item, i) => {
      if (typeof item !== "string") return item;
      const words = item.split(" ");
      if (i > 0 && typeof input[i - 1] !== "string") while (words.length > 1 && PUNCTUATION.test(words[0])) words.shift();
      if (i < input.length - 1 && typeof input[i + 1] !== "string") while (words.length > 1 && PUNCTUATION.test(words[words.length - 1])) words.pop();
      return words.join(" ");
    });
    const out = [];
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (typeof item !== "string" || !PUNCTUATION.test(item)) {
        out.push(item);
        continue;
      }
      const prev = out[out.length - 1];
      const next = list[i + 1];
      if (typeof prev === "string" && typeof next === "string" && !PUNCTUATION.test(next)) {
        out[out.length - 1] = `${prev} ${item} ${next}`;
        i++;
      }
    }
    return out;
  }

  function shape(nodes, options) {
    const out = [];
    for (const raw of foldPunctuation(nodes)) {
      if (typeof raw === "string") {
        out.push(raw);
        continue;
      }
      const n = Object.assign({}, raw);
      if (n.children) n.children = shape(n.children, options);
      // A link named only by an image's alt text, or not at all, is known by
      // where it goes.
      const kids = n.children || [];
      const imageOnly = kids.length > 0 && kids.every((c) => typeof c !== "string" && (c.role === "img" || c.role === "image"));
      if (n.role === "link" && n.url && (!n.name || imageOnly)) n.showUrl = true;
      // A caption, legend or label that names its container is not repeated.
      if (n.name && n.children && n.children.length > 1 && n.children[0] === n.name) n.children = n.children.slice(1);
      if (n.role === "row" && n.children && !hasRef(n.children) && n.children.every((c) => typeof c !== "string" && CELL_ROLES.has(c.role))) {
        const cells = n.children.map((c) => c.name || textOf(c.children));
        if (n.children.every((c) => c.role === "columnheader")) n.header = true;
        if (!n.name || squash(cells.join("")) === squash(n.name)) delete n.name;
        n.value = cells.join(" | ");
        delete n.children;
      } else if (n.name && n.children && squash(textOf(n.children)) === squash(n.name)) {
        // A name from content repeats the children. Keep the children when
        // they carry refs or the name is too long to print, else the name.
        // A control with its own ref keeps its name, so it can be told apart
        // (a <summary> disclosure around a link).
        if (hasRef(n.children)) {
          if (!n.ref) delete n.name;
        } else if (n.name.length > CONTENT_NAME_LIMIT) delete n.name;
        else {
          delete n.children;
          // The name is the content now, so it prints whole.
          n.contentName = true;
        }
      }
      // A lone text the name already says (an aria-label that extends the
      // visible text) is not repeated.
      if (n.name && n.children && n.children.length === 1 && typeof n.children[0] === "string" &&
          squash(n.name).includes(squash(n.children[0]))) delete n.children;
      if (n.children && !n.children.length) delete n.children;
      if (n.options && !(options.options || n.expanded === true)) {
        // A closed drop-down lists its options on its own line, capped.
        n.inlineOptions = n.options.map((o) => o.name);
        delete n.options;
      }

      // Structure with nothing in it says nothing.
      if (!n.act && !n.ref && !n.name && n.value === undefined && !n.children && !MEANINGFUL_EMPTY_ROLES.has(n.role)) continue;
      // An unnamed landmark or group directly around one of its own kind
      // adds nothing.
      if (!n.name && !n.ref && n.children && n.children.length === 1 && typeof n.children[0] !== "string" &&
          n.children[0].role === n.role && Object.keys(n).every((k) => k === "role" || k === "children")) {
        out.push(n.children[0]);
        continue;
      }
      // An unnamed list item or table cell around one element prints as
      // that element.
      if (TRANSPARENT_WRAPPERS.has(n.role) && !n.name && !n.ref && n.children && n.children.length === 1 &&
          typeof n.children[0] !== "string" && Object.keys(n).every((k) => k === "role" || k === "children")) {
        out.push(n.children[0]);
        continue;
      }
      out.push(n);
    }
    return out;
  }

  // Interactive nodes, the named ancestors that locate them, and the page
  // outline: headings and landmarks.
  function interactiveOnly(nodes) {
    const out = [];
    for (const n of nodes) {
      if (typeof n === "string") continue;
      if (n.role === "heading" && n.name && !n.act) {
        const heading = Object.assign({}, n);
        delete heading.children;
        out.push(heading);
        continue;
      }
      let kids = n.children ? interactiveOnly(n.children) : [];
      // An unnamed control is known by its text.
      if (n.act && !n.name) kids = [...(n.children || []).filter((c) => typeof c === "string"), ...kids];
      const copy = Object.assign({}, n);
      if (kids.length) copy.children = kids;
      else delete copy.children;
      if (n.act) out.push(copy);
      else if (kids.length && (n.name || n.role === "iframe" || LANDMARK_ROLES.has(n.role))) {
        delete copy.value;
        out.push(copy);
      } else out.push(...kids);
    }
    return out;
  }

  function nodeHead(n, options) {
    let head = n.role;
    if (n.header) head += " [header]";
    if (n.name) head += " " + q(n.name.length > NAME_LIMIT && !n.contentName ? n.name.slice(0, NAME_LIMIT - 1) + "…" : n.name);
    if (n.ref) head += ` [ref=${n.ref}]`;
    if (n.level !== undefined) head += ` [level=${n.level}]`;
    if (n.checked === true) head += " [checked]";
    else if (n.checked === "mixed") head += " [checked=mixed]";
    if (n.disabled) head += " [disabled]";
    if (n.expanded === true) head += " [expanded]";
    else if (n.expanded === false) head += " [expanded=false]";
    if (n.pressed === true) head += " [pressed]";
    else if (n.pressed === "mixed") head += " [pressed=mixed]";
    if (n.selected) head += " [selected]";
    if (n.required) head += " [required]";
    if (n.invalid) head += " [invalid]";
    if (n.readonly) head += " [readonly]";
    if (n.focused) head += " [focused]";
    if (n.hidden) head += " [hidden]";
    if (n.scrollable) head += " [scrollable]";
    if (n.url && options.urls) head += ` [url=${n.url}]`;
    else if (n.offsite) head += ` [url=${n.offsite}]`;
    // An unnamed link's on-site URL, capped: enough to tell such links apart.
    else if (n.url && n.showUrl) head += ` [url=${n.url.length > URL_LIMIT ? n.url.slice(0, URL_LIMIT - 1) + "…" : n.url}]`;
    if (n.placeholder) head += ` [placeholder=${q(n.placeholder)}]`;
    if (n.inlineOptions && n.inlineOptions.length) {
      const shown = n.inlineOptions.slice(0, INLINE_OPTIONS).join(", ");
      const more = n.inlineOptions.length - INLINE_OPTIONS;
      head += ` [options: ${shown}${more > 0 ? `, +${more} more` : ""}]`;
    }
    return head;
  }

  function render(nodes, options = {}, depth = 0, lines = []) {
    const indent = "  ".repeat(depth);
    for (const n of nodes) {
      if (typeof n === "string") {
        lines.push(`${indent}- text: ${q(n)}`);
        continue;
      }
      let head = nodeHead(n, options);
      let kids = n.children || [];
      if (n.value !== undefined && n.value !== null) head += ": " + q(n.value);
      else if (kids.length === 1 && typeof kids[0] === "string" && !n.options) {
        head += ": " + q(kids[0]);
        kids = [];
      } else if (kids.length || n.options) head += ":";
      lines.push(`${indent}- ${head}`);
      for (const o of n.options || []) lines.push(`${indent}  - option ${q(o.name)}${o.selected ? " [selected]" : ""}`);
      render(kids, options, depth + 1, lines);
    }
    return lines;
  }

  // ---------------------------------------------------------------------------
  // Diff: Myers line diff; each change is preceded by its unchanged ancestor
  // lines (by indentation) so it can be located without line numbers.

  function myers(a, b) {
    const N = a.length;
    const M = b.length;
    const MAX = N + M;
    if (!MAX) return [];
    const offset = MAX;
    const V = new Array(2 * MAX + 2).fill(-1);
    V[offset + 1] = 0;
    const trace = [];
    for (let d = 0; d <= MAX; d++) {
      trace.push(V.slice());
      for (let k = -d; k <= d; k += 2) {
        const down = k === -d || (k !== d && V[offset + k - 1] < V[offset + k + 1]);
        let x = down ? V[offset + k + 1] : V[offset + k - 1] + 1;
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
    for (let d = trace.length - 1; d >= 1; d--) {
      const V = trace[d];
      const k = x - y;
      const pk = k === -d || (k !== d && V[offset + k - 1] < V[offset + k + 1]) ? k + 1 : k - 1;
      const px = V[offset + pk];
      const py = px - pk;
      while (x > px && y > py) {
        x--;
        y--;
        out.push({ type: "equal", a: x, b: y });
      }
      if (x === px) out.push({ type: "insert", b: --y });
      else out.push({ type: "delete", a: --x });
    }
    while (x > 0 && y > 0) {
      x--;
      y--;
      out.push({ type: "equal", a: x, b: y });
    }
    return out.reverse();
  }

  const indentOf = (line) => /^ */.exec(line)[0].length;

  // Returns diff lines prefixed "  " (context), "- " (removed), "+ " (added)
  // or "~ " (changed, new version).
  // Empty when equal.
  function diffLines(previous, current) {
    const ops = myers(previous, current);
    const equalA = new Map();
    const equalB = new Set();
    for (const op of ops) {
      if (op.type === "equal") {
        equalA.set(op.a, op.b);
        equalB.add(op.b);
      }
    }
    const printed = new Set();
    const out = [];
    const context = (lines, index, isOld) => {
      const chain = [];
      let indent = indentOf(lines[index]);
      for (let j = index - 1; j >= 0 && indent > 0; j--) {
        const i = indentOf(lines[j]);
        if (i >= indent) continue;
        indent = i;
        const key = isOld ? equalA.get(j) : equalB.has(j) ? j : undefined;
        if (key !== undefined && !printed.has(key)) chain.unshift([key, lines[j]]);
      }
      for (const [key, line] of chain) {
        printed.add(key);
        out.push("  " + line);
      }
    };
    const emitDelete = (op) => {
      context(previous, op.a, true);
      out.push("- " + previous[op.a]);
    };
    const emitInsert = (op, mark = "+ ") => {
      context(current, op.b, false);
      out.push(mark + current[op.b]);
    };
    // Within a run of changes, a changed line's old version prints right
    // before its new version; other removals print first.
    for (let i = 0; i < ops.length;) {
      if (ops[i].type === "equal") {
        i++;
        continue;
      }
      const deletes = [];
      const inserts = [];
      for (; i < ops.length && ops[i].type !== "equal"; i++) (ops[i].type === "delete" ? deletes : inserts).push(ops[i]);
      const partner = new Map();
      const free = new Set(deletes);
      for (const ins of inserts) {
        const key = lineKey(current[ins.b]);
        const del = key && [...free].find((d) => lineKey(previous[d.a]) === key);
        if (del) {
          partner.set(ins, del);
          free.delete(del);
        }
      }
      for (const d of deletes) if (free.has(d)) emitDelete(d);
      // A changed line (same ref, else same role and name) prints once, as
      // its new version.
      for (const ins of inserts) emitInsert(ins, partner.has(ins) ? "~ " : "+ ");
    }
    return out;
  }

  // Identity of a snapshot line across a change: its ref, else its indent,
  // role and name. Unnamed lines without a ref have none.
  function lineKey(line) {
    const ref = /\[ref=(\w+)\]/.exec(line);
    if (ref) return ref[1];
    const m = /^( *- [\w-]+ "(?:[^"\\]|\\.)*")/.exec(line);
    return m ? m[1] : null;
  }

  // ---------------------------------------------------------------------------
  // Snapshot value

  const DIFF_HEADER = "# changes since the previous snapshot (+ added, - removed, ~ changed):";
  const NO_CHANGES = "# no changes since the previous snapshot";
  const FIRST = "# no previous snapshot of this tab; every line is new:";

  // From a full-tree diff, the added or changed lines that carry no ref and
  // are not containers (text, status, alert), each after the ancestor lines
  // that locate it. An interactive diff adds these, since an action's result
  // is often text the interactive tree leaves out.
  function textChanges(fullDiff) {
    const out = [];
    let ancestors = [];
    for (const line of fullDiff) {
      const body = line.slice(2);
      const depth = indentOf(body);
      ancestors = ancestors.filter((a) => indentOf(a.slice(2)) < depth);
      if (line.startsWith("  ")) {
        ancestors.push(line);
        continue;
      }
      if ((line.startsWith("+ ") || line.startsWith("~ ")) && !/\[ref=/.test(body) && !/:$/.test(body)) {
        out.push(...ancestors, line);
        ancestors = [];
      }
    }
    return out;
  }

  class Snapshot {
    constructor({ header, body, previous, maxChars, extraChanges }) {
      this._header = header;
      this._body = body;
      this._hasPrevious = !!previous;
      this._maxChars = maxChars;
      let changes = previous ? diffLines(previous, body) : body.map((l) => "+ " + l);
      if (previous && extraChanges && extraChanges.length) {
        // Lines the diff already printed (ancestors, or a heading the
        // interactive tree also holds) are not repeated.
        const printed = new Set(changes);
        const extra = extraChanges.filter((l) => !printed.has(l));
        // Ancestor lines left with no change under them go too.
        changes = changes.concat(extra.filter((l, i) => !l.startsWith("  ") || extra.slice(i + 1).some((m) => !m.startsWith("  ") && indentOf(m.slice(2)) > indentOf(l.slice(2)))));
      }
      this._diffBody = !previous ? [FIRST, ...changes] : changes.length ? [DIFF_HEADER, ...changes] : [NO_CHANGES];
    }
    _join(lines) {
      let text = lines.join("\n");
      const max = this._maxChars;
      if (typeof max === "number" && text.length > max) {
        const cut = text.lastIndexOf("\n", max);
        const kept = cut > 0 ? cut : max;
        text = text.slice(0, kept) + `\n# truncated: ${kept} of ${text.length} characters shown; scope with snapshot(ref) or { interactive: true }`;
      }
      return [...this._header, text].filter((s) => s !== "").join("\n");
    }
    get tree() {
      return this._join(this._body);
    }
    get diff() {
      return this._join(this._diffBody);
    }
    // Printing shows the diff when it is shorter than the tree, and for a
    // tree over DIFF_FLOOR characters when it saves at least 30%.
    get usesDiff() {
      if (!this._hasPrevious) return false;
      const diff = this._diffBody.join("\n").length;
      const tree = this._body.join("\n").length;
      return tree <= DIFF_FLOOR ? diff < tree : diff <= (1 - DIFF_SAVING) * tree;
    }
    toString() {
      return this.usesDiff ? this.diff : this.tree;
    }
    toJSON() {
      return this.toString();
    }
  }

  // ---------------------------------------------------------------------------
  // Capture

  const clock = () => (typeof performance !== "undefined" && performance.now ? performance.now() : Date.now());

  async function frameNodes(page, frame, rootHandle, options, focusChain) {
    const called = clock();
    const r = await frame._agent("snapshot", { root: rootHandle || null, showHidden: !!options.showHidden, viewport: !!options.viewport, base: page._refMaxFor(frame) });
    // Where the time goes, for tests/browser-parity/perf: in-page traversal
    // and the whole agent call (traversal plus transport).
    const timing = options._timing;
    if (timing) {
      timing.frames++;
      timing.agentMs += r.ms || 0;
      timing.callMs += clock() - called;
    }
    page._noteRefMax(frame, r.max);
    if (options.viewport) options._offscreen = (options._offscreen || 0) + (r.offscreen || 0);
    const prefix = page._prefixFor(frame);
    const fix = async (list) => {
      for (const node of list) {
        if (typeof node === "string") continue;
        if (node.ref) node.ref = prefix + node.ref;
        if (!focusChain) delete node.focused;
        if (node.role === "iframe") {
          const handle = node.frame;
          const focused = !!node.frameFocused;
          delete node.frame;
          delete node.frameFocused;
          const child = handle ? await frame._contentFrame(handle).catch(() => null) : null;
          if (child && !child._detached) {
            page._prefixFor(child);
            const inner = await frameNodes(page, child, null, options, focusChain && focused).catch(() => null);
            if (inner && inner.length) node.children = inner;
          }
        } else if (node.children) await fix(node.children);
      }
    };
    await fix(r.nodes);
    return r.nodes;
  }

  // Resolves snapshot()/screenshot() targets: a page, a locator, or a ref.
  async function resolveTarget(page, target) {
    if (!target || target instanceof core.Page) return { frame: page.mainFrame(), handle: null };
    const locator = typeof target === "string" ? page.ref(target) : target;
    if (!(locator instanceof core.Locator)) throw new TypeError("snapshot target must be a page, a locator or a ref");
    const r = await locator._resolveOne(true);
    if (!r) throw new Error(`snapshot: ${locator} matched no elements`);
    return { frame: r.frame, handle: r.handle };
  }

  async function blockingLines(page) {
    const lines = [];
    const dialog = page._pendingDialog();
    if (dialog) {
      let line = `dialog: ${dialog.type()} ${q(dialog.message())}`;
      if (dialog.type() === "prompt") line += ` [default=${q(dialog.defaultValue())}]`;
      lines.push(line + " (answer with page.dialog().accept() or .dismiss())");
    }
    const chooser = page._pendingChooser();
    if (chooser && !dialog) {
      const ref = await page._refForHandle(page._frameFor(chooser._p.frameId), chooser._p.element).catch(() => null);
      lines.push(`file chooser:${ref ? ` [ref=${ref}]` : ""}${chooser.isMultiple() ? " [multiple]" : ""} (answer with page.fileChooser().setFiles(paths) or .cancel())`);
    }
    return { lines, blocked: !!dialog };
  }

  async function capture(page, target, options) {
    await page._syncInfo().catch(() => {});
    if (!page._pendingDialog()) await page._refreshFrames().catch(() => {});
    const header = [`title: ${page._title || ""}`, `url: ${page.url()}`];
    const blocking = await blockingLines(page);
    header.push(...blocking.lines);
    if (blocking.blocked) return { header, body: ["# the page is blocked until the dialog is answered"], nodes: [] };
    const { frame, handle } = await resolveTarget(page, target);
    const raw = await frameNodes(page, frame, handle, options, true);
    const shaped = shape(raw, options);
    let nodes = shaped;
    if (options.interactive) nodes = interactiveOnly(nodes);
    const full = options.interactive ? render(shaped, options) : null;
    const body = render(nodes, options);
    if (options.viewport) body.push(`# ${options._offscreen || 0} interactive elements outside the viewport are not shown; snapshot() shows the whole page`);
    return { header, body, nodes, full };
  }

  async function takeSnapshot(page, target, options = {}) {
    const run = async () => {
      const started = clock();
      options = Object.assign({}, options);
      const timing = (options._timing = { frames: 0, agentMs: 0, callMs: 0 });
      const { header, body, full } = await capture(page, target, options);
      timing.captureMs = clock() - started;
      const scope = typeof target === "string" ? target : target instanceof core.Locator ? String(target) : "page";
      const key = [scope, !!options.interactive, !!options.showHidden, !!options.options, !!options.urls, !!options.viewport].join("|");
      const baselines = page._snapshotBaselines || (page._snapshotBaselines = new Map());
      const previous = baselines.get(key);
      baselines.set(key, body);
      let extraChanges;
      if (full) {
        const previousFull = baselines.get(key + "|full");
        baselines.set(key + "|full", full);
        if (previousFull && previous) extraChanges = textChanges(diffLines(previousFull, full));
      }
      const diffStarted = clock();
      const snap = new Snapshot({ header, body, previous, maxChars: options.maxChars, extraChanges });
      timing.diffMs = clock() - diffStarted;
      timing.totalMs = clock() - started;
      Object.defineProperty(snap, "_timing", { value: timing });
      return snap;
    };
    const prev = page._snapshotQueue || Promise.resolve();
    const next = prev.catch(() => {}).then(run);
    page._snapshotQueue = next;
    return next;
  }

  // Interactive refs in the viewport, drawn with their labels for a screenshot.
  async function annotate(page, target) {
    const { nodes } = await capture(page, target, { interactive: true });
    const byPrefix = new Map();
    const walk = (list) => {
      for (const n of list) {
        if (typeof n === "string") continue;
        if (n.ref && n.act) {
          const m = /^(f\d+)?(e\d+)$/.exec(n.ref);
          const prefix = m[1] || "";
          if (!byPrefix.has(prefix)) byPrefix.set(prefix, []);
          byPrefix.get(prefix).push([m[2], n.ref]);
        }
        if (n.children) walk(n.children);
      }
    };
    walk(nodes);
    const drawn = [];
    for (const [prefix, refs] of byPrefix) {
      const frame = page._frameForPrefix(prefix);
      if (!frame) continue;
      await frame._agent("annotate", refs);
      drawn.push(frame);
    }
    return async () => {
      for (const frame of drawn) await frame._agent("clearAnnotations").catch(() => {});
    };
  }

  ns.snapshot = { takeSnapshot, annotate, shape, interactiveOnly, render, diffLines, textChanges, myers, Snapshot, DIFF_SAVING, DIFF_FLOOR };
})(typeof globalThis !== "undefined" ? globalThis : this);
