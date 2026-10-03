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
        // The page agent sends only the first options of a long list.
        if (n.optionCount) n.inlineCount = n.optionCount;
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
    // An iframe whose frame did not answer in time.
    if (n.unread) head += ` [not read: ${n.unread}]`;
    if (n.url && options.urls) head += ` [url=${n.url}]`;
    else if (n.offsite) head += ` [url=${n.offsite}]`;
    // An unnamed link's on-site URL, capped: enough to tell such links apart.
    else if (n.url && n.showUrl) head += ` [url=${n.url.length > URL_LIMIT ? n.url.slice(0, URL_LIMIT - 1) + "…" : n.url}]`;
    if (n.placeholder) head += ` [placeholder=${q(n.placeholder)}]`;
    if (n.inlineOptions && n.inlineOptions.length) {
      const shown = n.inlineOptions.slice(0, INLINE_OPTIONS).join(", ");
      const more = (n.inlineCount || n.inlineOptions.length) - INLINE_OPTIONS;
      head += ` [options: ${shown}${more > 0 ? `, +${more} more` : ""}]`;
    }
    return head;
  }

  // A node's own lines (its head, and one line per option of an expanded
  // drop-down) and the children printed under it.
  function ownLines(n, options, indent) {
    let head = nodeHead(n, options);
    let kids = n.children || [];
    if (n.value !== undefined && n.value !== null) head += ": " + q(n.value);
    else if (kids.length === 1 && typeof kids[0] === "string" && !n.options) {
      head += ": " + q(kids[0]);
      kids = [];
    } else if (kids.length || n.options) head += ":";
    const lines = [`${indent}- ${head}`];
    for (const o of n.options || []) lines.push(`${indent}  - option ${q(o.name)}${o.selected ? " [selected]" : ""}`);
    return { lines, kids };
  }

  function render(nodes, options = {}, depth = 0, lines = []) {
    const indent = "  ".repeat(depth);
    for (const n of nodes) {
      if (typeof n === "string") {
        lines.push(`${indent}- text: ${q(n)}`);
        continue;
      }
      const own = ownLines(n, options, indent);
      for (const l of own.lines) lines.push(l);
      render(own.kids, options, depth + 1, lines);
    }
    return lines;
  }

  // ---------------------------------------------------------------------------
  // Printing within a budget. A snapshot's text (.tree, .diff) is complete;
  // what prints is at most `maxChars` characters (PRINT_BUDGET by default),
  // because printed output is what an agent pays for in context, and agent
  // harnesses cut or spill tool output past about 30,000 characters (Claude
  // Code) or 10,000 tokens (Codex). docs/browser-repl/performance.md has the
  // measurements behind the number.
  //
  // Over budget the tree is condensed, in this order of priority:
  //   1. on-screen controls, the focused element, and the page outline
  //      (landmarks, headings, iframes), with their ancestors;
  //   2. everything else in document order, except that a run of similar
  //      siblings (list items, table rows, cards) keeps its first items;
  //   3. the rest of those runs, in document order.
  // Whatever does not fit is replaced by one line where it was, saying how
  // much is left out and which ref scopes to it, and a closing note says how
  // to get everything.
  const PRINT_BUDGET = 20000;
  // A run of this many similar siblings keeps only its first RUN_KEEP in
  // step 2.
  const RUN_MIN = 6;
  const RUN_KEEP = 3;
  // A named region rides along with its heading.
  const OUTLINE_ROLES = new Set([...[...LANDMARK_ROLES].filter((r) => r !== "region"), "heading", "iframe"]);
  const INLINE_ROLES = new Set(["link", "button", "img", "image", "checkbox", "radio", "textbox", "combobox", "switch"]);

  const commas = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");

  // Items: one per printed node, with its own lines, its subtree's line and
  // ref counts, and its similarity signature (role plus the roles of its
  // children), in document order.
  function buildItems(nodes, options) {
    const items = [];
    const visit = (list, depth, parent) => {
      const out = [];
      for (const n of list) {
        const indent = "  ".repeat(depth);
        const item = { parent, depth, index: items.length, children: null, lines: null, refs: 0, total: 1, ref: null, sig: "text", include: false, tier: 1, run: null };
        items.push(item);
        if (typeof n === "string") {
          item.lines = [`${indent}- text: ${q(n)}`];
        } else {
          const own = ownLines(n, options, indent);
          item.lines = own.lines;
          item.ref = n.ref || null;
          item.role = n.role;
          item.node = n;
          const kinds = new Set();
          for (const c of own.kids) kinds.add(typeof c === "string" ? "text" : c.role);
          item.sig = n.role + "(" + [...kinds].sort().join(",") + ")";
          item.children = visit(own.kids, depth + 1, item);
        }
        item.cost = item.lines.reduce((a, l) => a + l.length + 1, 0);
        item.total = item.lines.length;
        item.refs = item.ref ? 1 : 0;
        item.subCost = item.cost;
        for (const c of item.children || []) {
          item.total += c.total;
          item.refs += c.refs;
          item.subCost += c.subCost;
        }
        out.push(item);
      }
      return out;
    };
    const roots = visit(nodes, 0, null);
    return { roots, items };
  }

  function condense(nodes, maxChars, options = {}) {
    const full = render(nodes, options);
    const fullLength = full.reduce((a, l) => a + l.length + 1, 0) - (full.length ? 1 : 0);
    if (!(maxChars < fullLength)) return full;
    const { roots, items } = buildItems(nodes, options);
    const scope = options._scope || null;
    const allRefs = roots.reduce((a, r) => a + r.refs, 0);
    const finalNote = (shown, refsShown) =>
      `# condensed to ${commas(shown)} of ${commas(fullLength)} characters (${commas(allRefs - refsShown)} of ${commas(allRefs)} refs not shown): ` +
      `snapshot(ref) prints a region, snapshot({ viewport: true }) what is on screen, ` +
      `snapshot(${scope ? scope + ", " : ""}{ maxChars: Infinity }) or .tree everything`;

    // Tiers: 0 pinned or outline (and their ancestors), 1 the rest, 2 the
    // tail of a long run of similar siblings.
    const raise = (item) => {
      for (let p = item; p && p.tier !== 0; p = p.parent) p.tier = 0;
    };
    const outline = [];
    for (const item of items) {
      const n = item.node;
      if (!n) continue;
      if (n.vp || n.focused) raise(item);
      else if (OUTLINE_ROLES.has(n.role)) outline.push(item);
    }
    // The outline goes in level by level (landmarks and frames, then h1,
    // h2, ...) while it fits in half the budget, with the ancestors it needs
    // and a note per entry: a page with 8,000 card headings keeps its
    // landmarks, not 8,000 lines.
    const allowance = (maxChars - 300) / 2;
    const levelOf = (it) => (it.node.role === "heading" ? it.node.level || 2 : 0);
    let spent = 0;
    for (let level = 0; level <= 6; level++) {
      const group = outline.filter((it) => levelOf(it) === level);
      const counted = new Set();
      let cost = 0;
      for (const it of group) {
        cost += 48;
        for (let p = it; p && p.tier !== 0 && !counted.has(p); p = p.parent) {
          counted.add(p);
          cost += p.cost;
        }
      }
      if (spent + cost > allowance) break;
      spent += cost;
      for (const it of group) raise(it);
    }
    // Runs of similar siblings, also repeating groups (a card flattened into
    // heading, text, link, button repeats with period 4): the first RUN_KEEP
    // repeats stay in tier 1, the rest drop to tier 2.
    const demote = (it) => {
      const stack = [it];
      while (stack.length) {
        const x = stack.pop();
        if (x.tier !== 0) x.tier = 2;
        for (const c of x.children || []) stack.push(c);
      }
    };
    const markRuns = (list) => {
      const n = list.length;
      for (let i = 0; i < n;) {
        let best = null;
        for (let period = 1; period <= 8 && i + period < n; period++) {
          let j = i;
          while (j + period < n && list[j].sig === list[j + period].sig) j++;
          const repeats = Math.floor((j - i + period) / period);
          // Prose (text between links) repeats too, but is read in order: a
          // run needs a block in its unit (an item, a row, a heading).
          if (repeats < RUN_MIN || !list.slice(i, i + period).some((it) => it.role && !INLINE_ROLES.has(it.role))) continue;
          if (!best || repeats * period > best.repeats * best.period) best = { period, repeats };
        }
        if (!best) {
          i++;
          continue;
        }
        const run = { period: best.period, kinds: list.slice(i, i + best.period).map((it) => it.role || "text") };
        const end = i + best.repeats * best.period;
        for (let k = i; k < end; k++) list[k].run = run;
        for (let k = i + RUN_KEEP * best.period; k < end; k++) if (list[k].tier !== 0) demote(list[k]);
        i = end;
      }
      for (const it of list) if (it.children) markRuns(it.children);
    };
    markRuns(roots);

    // One pass per budget: pick items, render them with their notes. A pass
    // that overshoots (notes cost more than reserved) runs again with less.
    let budget = maxChars - finalNote(fullLength, allRefs).length - 1;
    let lines = [];
    for (let attempt = 0; attempt < 6 && budget > 0; attempt++) {
      for (const it of items) {
        it.include = false;
        it.left = it.children ? it.children.length : 0;
      }
      const lineCap = Math.max(80, Math.floor(budget / 4));
      const costOf = (it) => Math.min(it.cost, lineCap + 20);
      // An included item whose children are not all included prints a note
      // under it; its cost is held from the start and returned once every
      // child is in. The top level holds one too.
      const noteCost = (it) => 2 * (it.depth + 1) + 40 + (it.ref || "").length;
      let rootsLeft = roots.length;
      let used = 40;
      const take = (it) => {
        if (it.include) return true;
        if (it.parent && !it.parent.include) return false;
        const c = costOf(it) + (it.left ? noteCost(it) : 0);
        if (used + c > budget) return false;
        it.include = true;
        used += c;
        if (it.parent) {
          if (--it.parent.left === 0) used -= noteCost(it.parent);
        } else if (--rootsLeft === 0) used -= 40;
        return true;
      };
      // Tier 0 in document order; an item needs its parent first, which
      // document order guarantees.
      for (const it of items) if (it.tier === 0) take(it);
      // Tiers 1 and 2 in document order, each stopping at the first item
      // that does not fit so what prints stays contiguous.
      // A small subtree (a list item, a card) goes in whole or not at all.
      const small = Math.max(200, budget / 10);
      const subtree = (it, out = []) => {
        out.push(it);
        for (const c of it.children || []) subtree(c, out);
        return out;
      };
      for (const tier of [1, 2]) {
        for (const it of items) {
          if (it.tier !== tier || it.include || (it.parent && !it.parent.include)) continue;
          if (it.children && it.subCost <= small) {
            const all = subtree(it).filter((x) => !x.include);
            if (used + all.reduce((a, x) => a + costOf(x), 0) + noteCost(it) > budget) break;
            for (const x of all) take(x);
          } else if (!take(it)) break;
        }
      }
      lines = [];
      let refsShown = 0;
      const emit = (list, parent) => {
        let skipped = [];
        const flush = () => {
          if (!skipped.length) return;
          const indent = "  ".repeat(skipped[0].depth);
          const refs = skipped.reduce((a, s) => a + s.refs, 0);
          const run = skipped[0].run;
          const sameRun = run && skipped.every((s) => s.run === run) && skipped.length % run.period === 0;
          let count;
          if (sameRun && run.period === 1 && skipped[0].role) count = `${commas(skipped.length)} more ${skipped[0].role}`;
          else if (sameRun && run.period > 1) count = `${commas(skipped.length / run.period)} more repeats of ${run.kinds.join(", ")}`;
          else count = `${commas(skipped.reduce((a, s) => a + s.total, 0))} more line${skipped.length === 1 && skipped[0].total === 1 ? "" : "s"}`;
          let scopeRef = null;
          for (let p = parent; p && !scopeRef; p = p.parent) scopeRef = p.ref;
          lines.push(`${indent}- … ${count}${refs ? ` (${commas(refs)} ref${refs === 1 ? "" : "s"})` : ""}${scopeRef ? `: snapshot(${q(scopeRef)})` : ""}`);
          skipped = [];
        };
        for (const it of list) {
          if (!it.include) {
            skipped.push(it);
            continue;
          }
          flush();
          if (it.ref) refsShown++;
          for (const l of it.lines) {
            // A single line longer than a quarter of the budget prints its start.
            lines.push(l.length > lineCap ? `${l.slice(0, lineCap)}…" (${commas(l.length)} characters)` : l);
          }
          if (it.children) emit(it.children, it);
        }
        flush();
      };
      emit(roots, null);
      const text = lines.join("\n");
      const note = finalNote(text.length, refsShown);
      if (text.length + 1 + note.length <= maxChars) {
        lines.push(note);
        return lines;
      }
      budget -= text.length + 1 + note.length - maxChars + 16;
    }
    // Nothing fits: cut the plain text.
    return cutLines(full, maxChars, fullLength);
  }

  // The first lines that fit in maxChars, and a note.
  function cutLines(lines, maxChars, total) {
    const out = [];
    let used = 0;
    const room = maxChars - 120;
    for (const l of lines) {
      if (used + l.length + 1 > room) break;
      out.push(l);
      used += l.length + 1;
    }
    out.push(`# truncated: ${commas(used)} of ${commas(total)} characters shown; .tree has everything`);
    return out;
  }

  // ---------------------------------------------------------------------------
  // Diff. Lines that occur once in both versions anchor the diff (patience
  // diff: the longest increasing run of such anchors); refs make most element
  // lines unique, so this is near-linear on snapshots. Between anchors a
  // Myers diff with a bounded edit distance fills in; past the bound the
  // span is a replacement. Each change is then preceded by its unchanged
  // ancestor lines (by indentation) so it can be located without line
  // numbers.

  // Myers' work bound per span: (N + M) * D steps.
  const MYERS_WORK = 20000000;

  function diffOps(a, b) {
    const ops = [];
    diffSpan(a, 0, a.length, b, 0, b.length, ops);
    return ops;
  }

  function diffSpan(a, a0, a1, b, b0, b1, ops) {
    while (a0 < a1 && b0 < b1 && a[a0] === b[b0]) ops.push({ type: "equal", a: a0++, b: b0++ });
    let s = 0;
    while (a1 - s > a0 && b1 - s > b0 && a[a1 - 1 - s] === b[b1 - 1 - s]) s++;
    a1 -= s;
    b1 -= s;
    if (a0 === a1) for (let j = b0; j < b1; j++) ops.push({ type: "insert", b: j });
    else if (b0 === b1) for (let i = a0; i < a1; i++) ops.push({ type: "delete", a: i });
    else {
      const anchors = uniqueAnchors(a, a0, a1, b, b0, b1);
      if (anchors.length) {
        let pa = a0;
        let pb = b0;
        for (const [i, j] of anchors) {
          diffSpan(a, pa, i, b, pb, j, ops);
          ops.push({ type: "equal", a: i, b: j });
          pa = i + 1;
          pb = j + 1;
        }
        diffSpan(a, pa, a1, b, pb, b1, ops);
      } else myersSpan(a, a0, a1, b, b0, b1, ops);
    }
    for (let k = 0; k < s; k++) ops.push({ type: "equal", a: a1 + k, b: b1 + k });
  }

  // Pairs [i, j] of lines that occur exactly once in a[a0..a1) and once in
  // b[b0..b1), reduced to the longest run increasing in both.
  function uniqueAnchors(a, a0, a1, b, b0, b1) {
    const seen = new Map();
    for (let i = a0; i < a1; i++) {
      const e = seen.get(a[i]);
      if (e) e.na++;
      else seen.set(a[i], { na: 1, i, nb: 0, j: -1 });
    }
    for (let j = b0; j < b1; j++) {
      const e = seen.get(b[j]);
      if (e) {
        e.nb++;
        e.j = j;
      }
    }
    const pairs = [];
    for (let i = a0; i < a1; i++) {
      const e = seen.get(a[i]);
      if (e.na === 1 && e.nb === 1) pairs.push([i, e.j]);
    }
    if (pairs.length <= 1) return pairs;
    // Longest increasing subsequence on j (patience sorting).
    const tails = [];
    const prev = new Array(pairs.length);
    for (let p = 0; p < pairs.length; p++) {
      const j = pairs[p][1];
      let lo = 0;
      let hi = tails.length;
      while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (pairs[tails[mid]][1] < j) lo = mid + 1;
        else hi = mid;
      }
      prev[p] = lo > 0 ? tails[lo - 1] : -1;
      tails[lo] = p;
    }
    const out = [];
    for (let p = tails[tails.length - 1]; p >= 0; p = prev[p]) out.push(pairs[p]);
    return out.reverse();
  }

  // Myers' O((N+M)D) diff over a span, keeping only the [-d, d] band of each
  // step (O(D^2) memory). Past MYERS_WORK the span is a replacement.
  function myersSpan(a, a0, a1, b, b0, b1, ops) {
    const N = a1 - a0;
    const M = b1 - b0;
    const maxD = Math.min(N + M, Math.max(16, Math.floor(MYERS_WORK / (N + M))));
    const off = maxD + 1;
    const V = new Int32Array(2 * maxD + 3).fill(-1);
    V[off + 1] = 0;
    const trace = [];
    for (let d = 0; d <= maxD; d++) {
      for (let k = -d; k <= d; k += 2) {
        const down = k === -d || (k !== d && V[off + k - 1] < V[off + k + 1]);
        let x = down ? V[off + k + 1] : V[off + k - 1] + 1;
        let y = x - k;
        while (x < N && y < M && a[a0 + x] === b[b0 + y]) {
          x++;
          y++;
        }
        V[off + k] = x;
        if (x >= N && y >= M) {
          trace.push(V.slice(off - d, off + d + 1));
          return myersBacktrack(trace, N, M, a0, b0, ops);
        }
      }
      trace.push(V.slice(off - d, off + d + 1));
    }
    for (let i = a0; i < a1; i++) ops.push({ type: "delete", a: i });
    for (let j = b0; j < b1; j++) ops.push({ type: "insert", b: j });
  }
  function myersBacktrack(trace, N, M, a0, b0, ops) {
    let x = N;
    let y = M;
    const out = [];
    for (let d = trace.length - 1; d >= 1; d--) {
      const Vp = trace[d - 1];
      const at = (k) => Vp[k + d - 1];
      const k = x - y;
      const pk = k === -d || (k !== d && at(k - 1) < at(k + 1)) ? k + 1 : k - 1;
      const px = at(pk);
      const py = px - pk;
      while (x > px && y > py) {
        x--;
        y--;
        out.push({ type: "equal", a: a0 + x, b: b0 + y });
      }
      if (x === px) out.push({ type: "insert", b: b0 + --y });
      else out.push({ type: "delete", a: a0 + --x });
    }
    while (x > 0 && y > 0) {
      x--;
      y--;
      out.push({ type: "equal", a: a0 + x, b: b0 + y });
    }
    for (let i = out.length - 1; i >= 0; i--) ops.push(out[i]);
  }

  // The kept name of the old export: a full-array diff.
  const myers = diffOps;

  const indentOf = (line) => /^ */.exec(line)[0].length;

  // The nearest line above each line with a smaller indent, or -1.
  function parentsOf(lines) {
    const parent = new Int32Array(lines.length);
    const stack = [];
    for (let i = 0; i < lines.length; i++) {
      const indent = indentOf(lines[i]);
      while (stack.length && indentOf(lines[stack[stack.length - 1]]) >= indent) stack.pop();
      parent[i] = stack.length ? stack[stack.length - 1] : -1;
      stack.push(i);
    }
    return parent;
  }

  // Returns diff lines prefixed "  " (context), "- " (removed), "+ " (added)
  // or "~ " (changed, new version).
  // Empty when equal.
  function diffLines(previous, current) {
    const ops = diffOps(previous, current);
    const equalA = new Map();
    const equalB = new Set();
    for (const op of ops) {
      if (op.type === "equal") {
        equalA.set(op.a, op.b);
        equalB.add(op.b);
      }
    }
    let parentsA = null;
    let parentsB = null;
    const printed = new Set();
    const out = [];
    const context = (lines, index, isOld) => {
      const parents = isOld ? parentsA || (parentsA = parentsOf(previous)) : parentsB || (parentsB = parentsOf(current));
      const chain = [];
      for (let j = parents[index]; j >= 0; j = parents[j]) {
        const key = isOld ? equalA.get(j) : equalB.has(j) ? j : undefined;
        if (key === undefined) continue;
        // An ancestor already printed means the rest of the chain was too.
        if (printed.has(key)) break;
        chain.unshift([key, lines[j]]);
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
      const byKey = new Map();
      for (const d of deletes) {
        const key = lineKey(previous[d.a]);
        if (!key) continue;
        if (!byKey.has(key)) byKey.set(key, []);
        byKey.get(key).push(d);
      }
      const partnered = new Set();
      const changed = new Set();
      for (const ins of inserts) {
        const key = lineKey(current[ins.b]);
        const list = key && byKey.get(key);
        if (list && list.length) {
          partnered.add(list.shift());
          changed.add(ins);
        }
      }
      for (const d of deletes) if (!partnered.has(d)) emitDelete(d);
      // A changed line (same ref, else same role and name) prints once, as
      // its new version.
      for (const ins of inserts) emitInsert(ins, changed.has(ins) ? "~ " : "+ ");
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

  // The longest header line printed (the title, URL and dialog lines are the page's).
  const HEADER_LINE_MAX = 500;
  // Header text comes from the page and reaches the caller's terminal, so
  // escape sequences (CSI, and OSC, DCS, SOS, PM and APC up to their
  // terminator, in 7- and 8-bit forms) and every other C0 or C1 control go,
  // and a long line is cut with its length.
  function headerLine(text) {
    const clean = String(text)
      .replace(/(?:\u001b\[|\u009b)[0-?]*[ -/]*[@-~]?/g, "")
      .replace(/(?:\u001b[\]PX^_]|[\u0090\u0098\u009d\u009e\u009f])[\s\S]*?(?:\u0007|\u009c|\u001b\\|$)/g, "")
      .replace(/[\t\n\r]/g, " ")
      .replace(/[\u0000-\u001f\u007f-\u009f]/g, "");
    if (clean.length <= HEADER_LINE_MAX) return clean;
    return `${clean.slice(0, HEADER_LINE_MAX)}… (${commas(clean.length - HEADER_LINE_MAX)} more characters)`;
  }

  class Snapshot {
    constructor({ header, body, nodes, trailer, previous, maxChars, extraChanges }) {
      this._header = header.map(headerLine);
      this._body = body;
      this._nodes = nodes || null;
      this._trailer = trailer || [];
      this._hasPrevious = !!previous;
      this._maxChars = maxChars === undefined || maxChars === null ? PRINT_BUDGET : maxChars;
      this._scope = null;
      let changes = previous ? diffLines(previous, body) : body.map((l) => "+ " + l);
      if (previous && extraChanges && extraChanges.length) {
        // Lines the diff already printed (ancestors, or a heading the
        // interactive tree also holds) are not repeated.
        const printed = new Set(changes);
        const extra = extraChanges.filter((l) => !printed.has(l));
        // Ancestor lines left with no change under them go too: keep a
        // context line only when a later change line is deeper.
        const keep = new Array(extra.length);
        let deepestChange = -1;
        for (let i = extra.length - 1; i >= 0; i--) {
          const l = extra[i];
          const depth = indentOf(l.slice(2));
          if (!l.startsWith("  ")) {
            keep[i] = true;
            deepestChange = Math.max(deepestChange, depth);
          } else keep[i] = deepestChange > depth;
        }
        changes = changes.concat(extra.filter((_, i) => keep[i]));
      }
      this._diffBody = !previous ? [FIRST, ...changes] : changes.length ? [DIFF_HEADER, ...changes] : [NO_CHANGES];
    }
    _join(lines) {
      return [...this._header, lines.join("\n")].filter((s) => s !== "").join("\n");
    }
    // The complete tree and diff; printing is what the budget limits.
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
      if (this._printed !== undefined) return this._printed;
      const max = this._maxChars;
      let text;
      if (this.usesDiff && (text = this.diff).length <= max) return (this._printed = text);
      text = this.tree;
      if (text.length <= max) return (this._printed = text);
      // Over budget: condense the tree. A diff that did not fit is on .diff.
      const extra = [...(this.usesDiff ? [DIFF_NOTE] : []), ...this._trailer];
      const room = max - [...this._header, ...extra].reduce((a, l) => a + l.length + 1, 0);
      const options = Object.assign({}, this._renderOptions, { _scope: this._scope });
      const body = this._nodes && room > 0 ? condense(this._nodes, room, options) : cutLines(this._body, Math.max(room, 0), this._body.join("\n").length);
      if (this.usesDiff) body.unshift(DIFF_NOTE);
      body.push(...this._trailer);
      return (this._printed = this._join(body));
    }
    toJSON() {
      return this.toString();
    }
  }
  const DIFF_NOTE = "# the changes since the previous snapshot do not fit the print budget; .diff has them";

  // ---------------------------------------------------------------------------
  // Capture

  const clock = () => (typeof performance !== "undefined" && performance.now ? performance.now() : Date.now());

  // Driver calls in flight at once while reading a page's frames. The app's
  // driver finds a frame without reading the frame tree, so hundreds of
  // calls in flight cost about what they do one at a time; the bound only
  // keeps a page of thousands of frames from queueing them all at once. On
  // 300 iframes the app takes 137 ms at 256, 257 ms at 32, 549 ms at 8.
  const FRAME_CONCURRENCY = 256;
  function limiter(max) {
    let active = 0;
    const waiting = [];
    return async (fn) => {
      if (active >= max) await new Promise((resolve) => waiting.push(resolve));
      active++;
      try {
        return await fn();
      } finally {
        active--;
        const next = waiting.shift();
        if (next) next();
      }
    };
  }

  // A frame inside the page that does not answer within this time is left
  // out (its iframe line says so) instead of holding up the snapshot.
  const FRAME_TIMEOUT = 10000;
  class FrameTimeout extends Error {}
  function withDeadline(page, promise, ms) {
    const host = page._session.host;
    return new Promise((resolve, reject) => {
      const timer = host.setTimeout(() => reject(new FrameTimeout("frame did not answer")), ms || FRAME_TIMEOUT);
      promise.then(
        (value) => {
          host.clearTimeout(timer);
          resolve(value);
        },
        (error) => {
          host.clearTimeout(timer);
          reject(error);
        },
      );
    });
  }

  // Reads a frame's tree and, a few at a time, the trees of the frames
  // inside it.
  async function frameTree(page, frame, rootHandle, options, inner) {
    const limit = options._limit || (options._limit = limiter(FRAME_CONCURRENCY));
    let called = 0;
    const read = () => frame._agent("snapshot", { root: rootHandle || null, showHidden: !!options.showHidden, viewport: !!options.viewport, options: !!options.options, base: page._refMaxFor(frame) });
    const r = await limit(() => ((called = clock()), inner ? withDeadline(page, read(), options._frameTimeout) : read()));
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
    const iframes = [];
    const collect = (list) => {
      for (const n of list) {
        if (typeof n === "string") continue;
        if (n.role === "iframe") iframes.push(n);
        else if (n.children) collect(n.children);
      }
    };
    collect(r.nodes);
    // All iframes of this frame resolve to their frames in one driver call
    // (frame.contentFrames); a driver without it answers per iframe.
    const handles = iframes.map((n) => n.frame).filter(Boolean);
    let batch = null;
    if (handles.length && page._batchContentFrames !== false) {
      try {
        const found = await limit(() => withDeadline(page, frame._session.call("frame.contentFrames", { targetId: page._targetId, frameId: frame._id || undefined, elements: handles }), options._frameTimeout));
        batch = new Map(handles.map((h, i) => [h, found[i] && found[i].frameId ? page._frameFor(found[i].frameId, frame) : null]));
      } catch (e) {
        if (e && e.code === "unsupported") page._batchContentFrames = false;
      }
    }
    await Promise.all(iframes.map(async (node) => {
      let child = null;
      try {
        if (batch) child = batch.get(node.frame) || null;
        else child = node.frame ? await limit(() => withDeadline(page, frame._contentFrame(node.frame), options._frameTimeout)) : null;
        if (child && !child._detached) node._child = { frame: child, tree: await frameTree(page, child, null, options, true) };
      } catch (e) {
        if (e instanceof FrameTimeout) node._child = { frame: child, timedOut: true };
        else if (child && !child._detached) node._child = { frame: child, tree: null };
      }
    }));
    return { frame, nodes: r.nodes };
  }

  // Prefixes refs with their frame's prefix and inlines each frame's tree
  // under its iframe. Prefixes are handed out here, in document order and
  // depth first, so they do not depend on which frame answered first.
  // `[focused]` holds only along the focused frame chain, and on-screen marks
  // only inside iframes that are on screen.
  function stitch(page, tree, focusChain, onScreen) {
    const prefix = page._prefixFor(tree.frame);
    const fix = (list) => {
      for (const node of list) {
        if (typeof node === "string") continue;
        if (node.ref) node.ref = prefix + node.ref;
        if (!focusChain) delete node.focused;
        if (!onScreen) delete node.vp;
        if (node.role === "iframe") {
          const focused = !!node.frameFocused;
          const child = node._child;
          const shown = !!node.vp;
          delete node.frame;
          delete node.frameFocused;
          delete node._child;
          if (child && child.timedOut) node.unread = "timed out";
          if (child && child.tree) {
            const inner = stitch(page, child.tree, focusChain && focused, shown);
            if (inner.length) node.children = inner;
          } else if (child && child.frame) page._prefixFor(child.frame);
        } else if (node.children) fix(node.children);
      }
    };
    fix(tree.nodes);
    return tree.nodes;
  }

  async function frameNodes(page, frame, rootHandle, options, focusChain) {
    return stitch(page, await frameTree(page, frame, rootHandle, options), focusChain, true);
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
    // Dialogs cmux dismissed during Copy, Cut or Paste, reported once.
    const lines = page._dismissedDialogs.splice(0).map((d) => `dialog dismissed: ${d.type()} ${q(d.message())} (it opened during a ${d._p.dismissedDuring})`);
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
    const trailer = options.viewport ? [`# ${options._offscreen || 0} interactive elements outside the viewport are not shown; snapshot() shows the whole page`] : [];
    body.push(...trailer);
    return { header, body, nodes, full, trailer };
  }

  async function takeSnapshot(page, target, options = {}) {
    const run = async () => {
      const started = clock();
      options = Object.assign({}, options);
      const timing = (options._timing = { frames: 0, agentMs: 0, callMs: 0 });
      const { header, body, full, nodes, trailer } = await capture(page, target, options);
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
      const snap = new Snapshot({ header, body, nodes, trailer, previous, maxChars: options.maxChars, extraChanges });
      // What a condensed print names as the scope that has everything.
      snap._scope = typeof target === "string" ? q(target) : target instanceof core.Locator ? "locator" : null;
      snap._renderOptions = options;
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

  ns.snapshot = { takeSnapshot, annotate, frameNodes, shape, interactiveOnly, render, condense, diffLines, diffOps, textChanges, myers, Snapshot, DIFF_SAVING, DIFF_FLOOR, PRINT_BUDGET };
})(typeof globalThis !== "undefined" ? globalThis : this);
