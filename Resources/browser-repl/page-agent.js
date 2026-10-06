// cmux browser REPL page agent.
//
// Installed by the driver into every frame's isolated "agent" world. It owns
// this frame's part of the snapshot tree, the ref table, element handles, and
// the DOM helpers the runtime's actionability checks need. Locator semantics
// come from Playwright's InjectedScript so they match Playwright exactly.
//
// Install recipe (drivers build this string once per frame document):
//
//   (() => {
//     const module = {};
//     <vendor/playwright-injected.js>
//     const __cmuxInjectedScriptFactory = module.exports.InjectedScript;
//     <page-agent.js>
//   })();
//
// The agent is stored on globalThis under Symbol.for("cmux.browserRepl.agent")
// as a non-enumerable property. Runtime code reaches it with
// `globalThis[Symbol.for("cmux.browserRepl.agent")]`.
(function (global, injectedFactory, ariaCaches) {
  "use strict";
  const KEY = Symbol.for("cmux.browserRepl.agent");
  if (global[KEY]) return;

  const document = global.document;

  // Sealed against other code in this world. In the app each session has a
  // world of its own (docs/browser-repl/driver-protocol.md, Agent world), so
  // another session's code never runs here; the session's own code does,
  // and in the dev driver every session shares the page's world. So the
  // agent keeps what binds refs and handles to elements out of that code's
  // reach: the agent object and its global are frozen and permanent, the
  // ref and handle tables are closures read through the built-ins as they
  // were at install (a later `Map.prototype.get` or `WeakRef.prototype.deref`
  // does not reach them), and the ref engine cannot be swapped.
  const uncurry = (fn) => Function.prototype.call.bind(fn);
  const mapGet = uncurry(Map.prototype.get);
  const mapSet = uncurry(Map.prototype.set);
  const mapHas = uncurry(Map.prototype.has);
  const mapDelete = uncurry(Map.prototype.delete);
  const mapForEach = uncurry(Map.prototype.forEach);
  const mapSize = uncurry(Object.getOwnPropertyDescriptor(Map.prototype, "size").get);
  const weakMapGet = uncurry(WeakMap.prototype.get);
  const weakMapSet = uncurry(WeakMap.prototype.set);
  const WeakRefClass = typeof global.WeakRef === "function" ? global.WeakRef : null;
  const weakDeref = WeakRefClass ? uncurry(WeakRefClass.prototype.deref) : null;
  const strTrim = uncurry(String.prototype.trim);
  const strIndexOf = uncurry(String.prototype.indexOf);
  const strSlice = uncurry(String.prototype.slice);
  const strEndsWith = uncurry(String.prototype.endsWith);
  const StringOf = String;
  const nodeProto = global.Node && global.Node.prototype;
  const nodeGetter = (name) => {
    const d = nodeProto && Object.getOwnPropertyDescriptor(nodeProto, name);
    return d && d.get ? uncurry(d.get) : (n) => n[name];
  };
  const ownerDocumentOf = nodeGetter("ownerDocument");
  const isConnectedOf = nodeGetter("isConnected");
  // A table entry holds its element weakly where the engine can.
  const weakRef = WeakRefClass ? (el) => new WeakRefClass(el) : (el) => Object.freeze({ el });
  const derefEntry = (entry) => (!entry ? undefined : weakDeref ? weakDeref(entry) : entry.el);

  // The app's agent world sees closed shadow roots (WebKit's
  // allowAccessToClosedShadowRoots). WebKit's switch also opens user-agent
  // roots (the internals of <details>, <summary>, <input>, <video>), which
  // are not page content. Only custom elements and these HTML elements can
  // host an author shadow root (DOM Standard, attachShadow), so this world's
  // `shadowRoot` returns a root only for them. Page worlds are unaffected.
  const AUTHOR_SHADOW_HOSTS = new Set(["article", "aside", "blockquote", "body", "div", "footer", "h1", "h2", "h3", "h4",
    "h5", "h6", "header", "main", "nav", "p", "section", "span"]);
  const HTML_NS = "http://www.w3.org/1999/xhtml";
  const shadowRootDescriptor = global.Element && Object.getOwnPropertyDescriptor(global.Element.prototype, "shadowRoot");
  if (shadowRootDescriptor && shadowRootDescriptor.get && shadowRootDescriptor.configurable) {
    const read = shadowRootDescriptor.get;
    Object.defineProperty(global.Element.prototype, "shadowRoot", {
      configurable: false,
      enumerable: shadowRootDescriptor.enumerable,
      get() {
        const root = read.call(this);
        if (!root) return null;
        const name = this.localName || "";
        return this.namespaceURI === HTML_NS && (name.includes("-") || AUTHOR_SHADOW_HOSTS.has(name)) ? root : null;
      },
    });
  }

  // `labels` of a form control. WebKit answers each read by scanning the
  // whole document (LabelsNodeList), so naming every button of a large page
  // is quadratic. While the DOM cannot change (a synchronous read such as a
  // snapshot), this world answers from an index built once per tree: the
  // <label> elements of the control's root, keyed by their labeled control.
  // That is the definition of `labels` (HTML, "labeled control"), so the
  // result is the same. Page worlds are unaffected.
  let labelIndex = null;
  const LABELABLE = ["HTMLButtonElement", "HTMLInputElement", "HTMLMeterElement", "HTMLOutputElement", "HTMLProgressElement",
    "HTMLSelectElement", "HTMLTextAreaElement"];
  for (const name of LABELABLE) {
    const proto = global[name] && global[name].prototype;
    const d = proto && Object.getOwnPropertyDescriptor(proto, "labels");
    if (!d || !d.get || !d.configurable) continue;
    const read = d.get;
    Object.defineProperty(proto, "labels", {
      configurable: false,
      enumerable: d.enumerable,
      get() {
        if (!labelIndex) return read.call(this);
        // A hidden input has no labels (null), as the native getter says.
        if (name === "HTMLInputElement" && (this.type || "").toLowerCase() === "hidden") return null;
        // An index the budget cut short has no answer, and WebKit's getter
        // would scan the whole document for each control: the cut read gets
        // no labels (it already says it was cut).
        const found = labelIndex(this);
        return found === null ? [] : found;
      },
    });
  }
  // Building it reads every <label> of the tree, which the page sets the
  // number of, so each one is charged to the read's budget (the snapshot's,
  // else a page-read budget of its own). An index the budget cut short
  // answers null, and that control has no labels in this read.
  let labelBudget = null;
  function createLabelIndex() {
    const byRoot = new Map();
    return (el) => {
      const root = el.getRootNode();
      let map = byRoot.get(root);
      if (map === undefined) {
        map = new Map();
        const b = labelBudget || (labelBudget = readBudget());
        const labels = root.querySelectorAll ? root.querySelectorAll("label") : [];
        for (const label of labels) {
          if (!spend(b, 1)) {
            map = null;
            break;
          }
          const control = label.control;
          if (!control) continue;
          if (!map.has(control)) map.set(control, []);
          map.get(control).push(label);
        }
        byRoot.set(root, map);
      }
      return map === null ? null : map.get(el) || [];
    };
  }
  // Runs `fn` with the label index, Playwright's aria caches and a computed
  // style cache. Only for synchronous reads: the DOM must not change inside.
  let styleCache = null;
  function withReadCaches(fn) {
    if (labelIndex) return fn();
    labelIndex = createLabelIndex();
    labelBudget = null;
    styleCache = new Map();
    if (ariaCaches) ariaCaches.begin();
    try {
      return fn();
    } finally {
      if (ariaCaches) ariaCaches.end();
      labelIndex = null;
      labelBudget = null;
      styleCache = null;
    }
  }

  let injected = null;
  if (injectedFactory) {
    const InjectedScript = injectedFactory();
    injected = new InjectedScript(global, {
      isUnderTest: false,
      sdkLanguage: "javascript",
      testIdAttributeName: "data-testid",
      stableRafCount: 1,
      browserName: "webkit",
      isUtilityWorld: true,
      customEngines: [],
    });
  }

  // ---------------------------------------------------------------------------
  // Handles

  // Handles hold their elements weakly: a connected element is kept alive by
  // its document, and one the page dropped cannot be acted on anyway.
  //
  // A frame keeps its id when it navigates, and each new document gets a new
  // agent that numbers from 1 again, so a handle carries this document's
  // token (`h<n>.<token>`, opaque to the host). A handle of another document
  // never resolves here, also when its number exists in this one: it fails
  // `stale` instead of acting on an element of another document (possibly
  // another origin). The token is random and lives only in this world.
  const docToken = (() => {
    const bytes = new Uint8Array(8);
    if (global.crypto && typeof global.crypto.getRandomValues === "function") global.crypto.getRandomValues(bytes);
    else for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  })();
  const PREVIOUS_DOCUMENT = "Element handle is from a previous document; take a new snapshot";
  let nextHandle = 1;
  const handleOf = new WeakMap();
  const handles = new Map();
  function handleFor(el) {
    let id = weakMapGet(handleOf, el);
    if (!id) {
      id = "h" + nextHandle++ + "." + docToken;
      weakMapSet(handleOf, el, id);
      mapSet(handles, id, weakRef(el));
    }
    return id;
  }
  // Whether `id` was issued by this document's agent.
  function isOwnHandle(id) {
    return typeof id === "string" && strEndsWith(id, "." + docToken);
  }
  // An element belongs to this agent only while it is in this document. A
  // same-origin page can move it into another frame's document (adoptNode,
  // or appendChild into a same-origin iframe or popup); it stays connected
  // there, but acting on it here would act under this frame's id (its
  // point, its file chooser) on another document, so it resolves as gone.
  const inThisDocument = (el) => !!el && ownerDocumentOf(el) === document;
  const OTHER_DOCUMENT = "Element handle is from a previous document: the page moved its element into another document; take a new snapshot";
  function handleElement(id) {
    if (!isOwnHandle(id)) return null;
    const el = derefEntry(mapGet(handles, id));
    return inThisDocument(el) ? el : null;
  }
  function element(id) {
    if (!isOwnHandle(id)) throw agentError("stale", PREVIOUS_DOCUMENT);
    const el = derefEntry(mapGet(handles, id));
    if (!el) throw agentError("stale", "Element handle is no longer available");
    if (!inThisDocument(el)) throw agentError("stale", OTHER_DOCUMENT);
    return el;
  }
  // Past this many entries, the ref and handle tables also drop elements
  // that are out of the document (a page that replaces its content keeps
  // adding refs, and WeakRefs are only cleared when the engine collects).
  // A dropped element that returns to the document gets its ref back from
  // `refOf` at the next snapshot.
  const TABLE_SOFT_LIMIT = 5000;
  function pruneHandles() {
    const large = mapSize(handles) > TABLE_SOFT_LIMIT;
    mapForEach(handles, (entry, id) => {
      const el = derefEntry(entry);
      if (!el || (large && !isConnectedOf(el))) mapDelete(handles, id);
    });
  }
  function agentError(code, message) {
    const e = new Error(message);
    e.code = code;
    return e;
  }

  const tagOf = (el) => (el.localName || el.tagName || "").toLowerCase();
  const styleOf = (el, pseudo) => {
    if (styleCache && !pseudo) {
      let style = styleCache.get(el);
      if (style === undefined) {
        try {
          style = global.getComputedStyle(el, null);
        } catch {
          style = null;
        }
        styleCache.set(el, style);
      }
      return style;
    }
    try {
      return global.getComputedStyle(el, pseudo || null);
    } catch {
      return null;
    }
  };
  const normalize = (s) => String(s || "").replace(/\s+/g, " ").trim();
  // Where this world cuts a page string, it leaves CUT until the reply is
  // sealed (`sealReply`). Secrets are masked natively, after the reply
  // leaves the page, by matching whole values, so a cut inside a value
  // would hand on its unmasked prefix: sealing drops the CUT_MARGIN
  // characters before each cut, the longest form a masked value takes
  // (4,096 bytes, BrowserReplSecretStore.maximumValueBytes, each character
  // at most 13 characters as an HTML reference, `&#1114111;`), and writes
  // "…" there. CUT is random and lives only in this world (as docToken), so
  // page text, which may hold any character, cannot forge a cut.
  const CUT = "\ufdd0" + docToken + "\ufdd0";
  const CUT_MARGIN = 13 * 4096;
  // `s` with each cut settled: the text within CUT_MARGIN before it dropped.
  function settleCuts(s) {
    if (typeof s !== "string" || s.indexOf(CUT) === -1) return s;
    let out = "";
    let from = 0;
    for (let i = s.indexOf(CUT); i !== -1; i = s.indexOf(CUT, from)) {
      let end = Math.max(from, i - CUT_MARGIN);
      // Never split a surrogate pair.
      if (end > from && /[\ud800-\udbff]/.test(s[end - 1])) end--;
      out += s.slice(from, end) + "…";
      from = i + CUT.length;
      while (s.startsWith(CUT, from)) from += CUT.length;
    }
    return out + s.slice(from);
  }
  // A safety cap only: the host decides how much of a name to print.
  const capName = (s) => (s.length > 2000 ? s.slice(0, 1999) + CUT : s);

  function parentCrossingShadow(el) {
    if (el.parentElement) return el.parentElement;
    const root = el.parentNode;
    if (root && root.nodeType === 11 && root.host) return root.host;
    return null;
  }

  function isContentEditableHost(el) {
    const ce = el.contentEditable;
    if (ce !== "true" && ce !== "plaintext-only") return false;
    const parent = parentCrossingShadow(el);
    return !(parent && parent.isContentEditable);
  }

  function pseudoText(el, pseudo) {
    const cs = styleOf(el, pseudo);
    if (!cs || cs.display === "none" || cs.visibility === "hidden") return "";
    const content = cs.content;
    if (!content || content === "none" || content === "normal") return "";
    let out = "";
    const re = /"((?:[^"\\]|\\[\s\S])*)"|'((?:[^'\\]|\\[\s\S])*)'/g;
    let m;
    while ((m = re.exec(content))) {
      const raw = m[1] !== undefined ? m[1] : m[2];
      out += raw.replace(/\\([nrtf"'\\])/g, (_, c) => ({ n: "\n", r: "\r", t: "\t", f: "\f" })[c] || c);
    }
    return out;
  }

  function deepActiveElement(doc) {
    let active = doc.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
    return active === doc.body || active === doc.documentElement ? null : active;
  }

  // ---------------------------------------------------------------------------
  // Refs. A ref names one DOM node for the node's life and is never reused in
  // this frame: the host passes `base`, the highest number it has seen here,
  // so numbering continues after the frame loads a new document. Another
  // session that drives the tab numbers from its own base, so the host also
  // checks each ref against the document that issued it (`doc`, the token
  // above): `refState` and the `aria-ref` engine refuse another document's.

  const refOf = new WeakMap();
  const refRegistry = new Map();
  let refCounter = 0;

  function raiseRefBase(base) {
    if (typeof base === "number" && base > refCounter) refCounter = base;
  }
  function refFor(el) {
    let ref = weakMapGet(refOf, el);
    if (!ref) {
      ref = "e" + ++refCounter;
      weakMapSet(refOf, el, ref);
      mapSet(refRegistry, ref, weakRef(el));
    } else if (!mapHas(refRegistry, ref)) mapSet(refRegistry, ref, weakRef(el));
    return ref;
  }
  function refElement(ref) {
    const el = derefEntry(mapGet(refRegistry, ref));
    return inThisDocument(el) && isConnectedOf(el) ? el : null;
  }
  function pruneRefs() {
    const large = mapSize(refRegistry) > TABLE_SOFT_LIMIT;
    mapForEach(refRegistry, (entry, ref) => {
      const el = derefEntry(entry);
      if (!el || (large && !isConnectedOf(el))) mapDelete(refRegistry, ref);
    });
  }

  // ---------------------------------------------------------------------------
  // Snapshot tree (docs/browser-repl/README.md, Snapshot). This builds a JSON
  // tree of roles, names, states and text; snapshot.js on the host stitches
  // frames and renders the text. Roles and names come from Playwright's
  // injected script, so they match getByRole().

  const SKIP_TAGS = new Set(["script", "style", "noscript", "template", "head", "meta", "link", "title", "base"]);
  // Structure that carries no meaning for an agent: its text joins the parent.
  // Paragraphs too: their text prints as its own lines either way.
  const FLATTEN_ROLES = new Set(["generic", "none", "presentation", "strong", "emphasis", "code", "mark", "subscript",
    "superscript", "deletion", "insertion", "time", "rowgroup", "paragraph"]);
  const FLATTEN_UNNAMED_ROLES = new Set(["group", "img", "image", "region", "caption"]);
  const INTERACTIVE_ROLES = new Set(["button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox",
    "option", "menuitem", "menuitemcheckbox", "menuitemradio", "slider", "spinbutton", "switch", "tab", "treeitem", "scrollbar"]);
  // Named landmarks, dialogs and lists get refs so a region can be scoped.
  const SCOPE_ROLES = new Set(["banner", "complementary", "contentinfo", "form", "main", "navigation", "region", "search",
    "dialog", "alertdialog", "list", "listbox", "menu", "menubar", "tablist", "tree", "treegrid", "grid"]);
  const CHECKED_ROLES = new Set(["checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio", "treeitem", "option"]);
  const SELECTED_ROLES = new Set(["tab", "option", "row", "gridcell", "treeitem", "columnheader", "rowheader"]);
  const VALUE_ROLES = new Set(["slider", "progressbar", "meter", "spinbutton", "scrollbar"]);
  const NO_VALUE_INPUTS = new Set(["checkbox", "radio", "button", "submit", "reset", "image", "hidden"]);
  const NOT_READONLY_INPUTS = new Set(["checkbox", "radio", "file", "button", "submit", "reset", "image", "range", "color", "hidden"]);
  // Options of a closed drop-down the host prints inline (snapshot.js).
  const INLINE_OPTIONS = 10;
  const LEAF_TAGS = new Set(["input", "textarea", "select", "img", "svg", "canvas", "progress", "meter", "video", "audio", "iframe", "frame"]);
  const BREAK = { brk: true };
  // Where a clipped element was left out; text brackets around it close up.
  const DROPPED = { dropped: true };

  // Tables used for page layout (Hacker News, old sites, emails) are not
  // data: their rows and cells flatten into the content, as Chromium's
  // accessibility tree does. A table is data when it declares any header,
  // caption or table structure; otherwise a table that holds or sits in
  // another table, a single row or column, or rows of differing lengths mark
  // it as layout.
  //
  // This runs before the walk visits the table's content, outside its node
  // budget, so it reads lazily and at most a bounded sample: the table's
  // first TABLE_SAMPLE children, rows and cells per row, and TABLE_SCAN of
  // its descendant elements when it looks for a nested table. A huge table
  // is judged by its start.
  const TABLE_SAMPLE = 50;
  const TABLE_SCAN = 1000;
  const layoutTables = new WeakMap();
  const TABLE_PART_TAGS = new Set(["table", "thead", "tbody", "tfoot", "tr", "td", "th"]);
  function hasColgroup(table) {
    let n = 0;
    for (let c = table.firstElementChild; c && n < TABLE_SAMPLE; c = c.nextElementSibling, n++) if (tagOf(c) === "colgroup") return true;
    return false;
  }
  function holdsTable(table) {
    const walker = table.ownerDocument.createTreeWalker(table, 1 /* NodeFilter.SHOW_ELEMENT */);
    for (let n = 0, el = walker.nextNode(); el && n < TABLE_SCAN; el = walker.nextNode(), n++) if (tagOf(el) === "table") return true;
    return false;
  }
  function isLayoutTable(table) {
    let layout = layoutTables.get(table);
    if (layout !== undefined) return layout;
    layout = false;
    if (!table.getAttribute("role") && !table.hasAttribute("summary") && !(Number(table.getAttribute("border")) > 0) &&
        !(table.caption || table.tHead || table.tFoot || hasColgroup(table))) {
      // Indexed reads walk only as far as the index (no `length`, no spread).
      const rows = table.rows;
      let rowCount = 0;
      let dataCell = false;
      const lengths = new Set();
      for (let row; rowCount < TABLE_SAMPLE && (row = rows[rowCount]); rowCount++) {
        let length = 0;
        const cells = row.cells;
        for (let i = 0, cell; i < TABLE_SAMPLE && (cell = cells[i]); i++) {
          length += cell.colSpan || 1;
          if (tagOf(cell) === "th" || cell.hasAttribute("scope") || cell.hasAttribute("headers") || cell.getAttribute("role")) dataCell = true;
        }
        if (length) lengths.add(length);
      }
      if (!dataCell) {
        const columns = Math.max(0, ...lengths);
        const nested = holdsTable(table) || !!(table.parentElement && table.parentElement.closest("td, th"));
        layout = nested || rowCount <= 1 || columns <= 1 || lengths.size > 1;
      }
    }
    layoutTables.set(table, layout);
    return layout;
  }
  function inLayoutTable(el, tag) {
    if (!TABLE_PART_TAGS.has(tag) || el.getAttribute("role")) return false;
    const table = tag === "table" ? el : el.closest("table");
    return !!table && isLayoutTable(table);
  }

  function roleOf(el) {
    const tag = tagOf(el);
    if (tag === "iframe" || tag === "frame") return "iframe";
    if (inLayoutTable(el, tag)) return "none";
    const explicit = (el.getAttribute("role") || "").trim();
    const role = injected ? injected.utils.getAriaRole(el) : null;
    if (role) return role;
    // Controls with no ARIA role in HTML-AAM, named the way Chromium exposes
    // them. getByRole() does not find these roles; their refs work.
    if (!explicit && tag === "summary") return "button";
    if (!explicit && tag === "canvas") return "canvas";
    if (!explicit && isContentEditableHost(el)) return "textbox";
    return "generic";
  }

  // Roles ARIA names from their content and that hold little else: their
  // content name is how an agent finds them. Containers that ARIA also names
  // from content (rows, cells, list and tree items) would repeat everything
  // their children print, so they take only an author name.
  const CONTENT_NAMED_ROLES = new Set(["button", "link", "heading", "option", "tab", "menuitem", "menuitemcheckbox",
    "menuitemradio", "checkbox", "radio", "switch", "tooltip", "treeitem"]);
  const AUTHOR_NAMED_ONLY_ROLES = new Set(["row", "cell", "gridcell", "columnheader", "rowheader", "listitem",
    "paragraph", "term", "definition", "blockquote", "status", "alert", "log", "note", "article"]);

  // A name reads page text (labels, aria-labelledby targets, the
  // element's own content) the snapshot walk may never visit, and
  // Playwright's name computation reads it whole and recursively. So the
  // text a name would read is counted first (nodes, characters, depth;
  // nodes outside the element charged to the snapshot's node budget, its
  // own content, which the walk reads anyway, to its clock): Playwright computes the
  // name only when it is within NAME_NODES, NAME_CHARS and NAME_DEPTH;
  // past them the name is read directly from the same sources, at most
  // NAME_CHARS characters and charged node by node. Attributes are cut
  // before they are normalized.
  const NAME_NODES = 2000;
  const NAME_CHARS = 20000;
  const NAME_DEPTH = 100;
  const NAME_FROM_CONTENT = new Set(["button", "cell", "checkbox", "columnheader", "gridcell", "heading", "link", "menuitem",
    "menuitemcheckbox", "menuitemradio", "option", "radio", "row", "rowheader", "switch", "tab", "tooltip", "treeitem"]);
  const NAME_ATTRS = ["aria-label", "title", "alt", "placeholder", "value", "aria-description"];
  const LABELABLE_TAGS = new Set(["input", "select", "textarea", "button", "meter", "output", "progress"]);
  const cutAttr = (v) => (v && v.length > NAME_CHARS ? v.slice(0, NAME_CHARS) + CUT : v || "");
  function labelledTargets(el, ctx) {
    const value = el.getAttribute("aria-labelledby");
    if (!value) return [];
    const out = [];
    const ids = /\S+/g;
    for (let m = ids.exec(value); m && out.length < 64 && spend(ctx, 1); m = ids.exec(value)) {
      const t = el.ownerDocument.getElementById(m[0]);
      if (t) out.push(t);
    }
    return out;
  }
  function nameRoots(el, role, tag, ctx) {
    const roots = labelledTargets(el, ctx);
    if (LABELABLE_TAGS.has(tag) && el.labels) for (const l of el.labels) roots.push(l);
    if (NAME_FROM_CONTENT.has(role) || tag === "summary") roots.push(el);
    else {
      const child = tag === "fieldset" ? "legend" : tag === "table" ? "caption" : tag === "figure" ? "figcaption" : null;
      if (child) for (let c = el.firstElementChild; c; c = c.nextElementSibling) if (tagOf(c) === child) roots.push(c);
    }
    return roots;
  }
  // Whether the sources of el's name are small enough for Playwright to
  // read whole; their nodes are charged to `ctx`.
  function nameFits(el, roots, ctx) {
    for (const a of NAME_ATTRS) {
      const v = el.getAttribute(a);
      if (v && v.length > NAME_CHARS) return false;
    }
    const queue = roots.slice();
    const seen = new Set();
    let nodes = 0;
    let chars = 0;
    for (let i = 0; i < queue.length; i++) {
      const root = queue[i];
      if (seen.has(root)) continue;
      seen.add(root);
      let depth = 0;
      let over = false;
      const own = root === el;
      walkTree(root, (n) => {
        if (++nodes > NAME_NODES) return (over = true), STOP;
        if (own ? ++ctx.ticks % 256 === 0 && now() > ctx.deadline && (ctx.truncated = ctx.truncated || "time") : !spend(ctx, 1)) return (over = true), STOP;
        if (n.nodeType === 3) chars += n.data.length;
        else if (n.nodeType === 1) {
          // A <select> in a label names it by its chosen options, not by
          // all of them.
          if (n !== root && tagOf(n) === "select") {
            for (const o of n.selectedOptions) {
              if (++nodes > NAME_NODES) return (over = true), STOP;
              chars += o.text.length;
            }
            return false;
          }
          if (++depth > NAME_DEPTH) return (over = true), STOP;
          for (const a of NAME_ATTRS) {
            const v = n.getAttribute(a);
            if (v) chars += v.length;
          }
          // Shadow content and aria-labelledby or aria-owns targets inside
          // the content are read too.
          if (n.shadowRoot) queue.push(n.shadowRoot);
          if (n !== root && n.hasAttribute("aria-labelledby")) queue.push(...labelledTargets(n, ctx));
          const owns = n.getAttribute("aria-owns");
          if (owns) for (const id of owns.split(/\s+/).slice(0, 64)) {
            const t = id && n.ownerDocument.getElementById(id);
            if (t) queue.push(t);
          }
        }
        if (chars > NAME_CHARS || queue.length > NAME_NODES) return (over = true), STOP;
        return true;
      }, (n) => {
        if (n.nodeType === 1) depth--;
      });
      if (over) return false;
    }
    return true;
  }
  // Text of `root` for a name: its text nodes in order (as textContent;
  // with `spaced`, a space at each element), at most NAME_CHARS characters
  // from at most NAME_NODES nodes, each charged to `ctx` (to its clock
  // only for `own` content, which the walk reads anyway).
  function boundedNameText(root, ctx, spaced, own) {
    let out = "";
    let nodes = 0;
    walkTree(root, (n) => {
      if (out.length >= NAME_CHARS || ++nodes > NAME_NODES) return STOP;
      if (own ? ++ctx.ticks % 256 === 0 && now() > ctx.deadline && (ctx.truncated = ctx.truncated || "time") : !spend(ctx, 1)) return STOP;
      if (n.nodeType === 3 || n.nodeType === 4) out += n.data.length > NAME_CHARS - out.length ? n.data.slice(0, NAME_CHARS - out.length) + CUT : n.data;
      else if (n.nodeType === 1 && spaced) {
        if (SKIP_TAGS.has(tagOf(n))) return false;
        if (out && out[out.length - 1] !== " ") out += " ";
        if (n !== root && tagOf(n) === "select") {
          const chosen = n.selectedOptions;
          for (let i = 0; i < chosen.length && i < NAME_NODES && out.length < NAME_CHARS; i++) {
            const t = chosen[i].text;
            out += (t.length > NAME_CHARS - out.length ? t.slice(0, NAME_CHARS - out.length) + CUT : t) + " ";
          }
          return false;
        }
      }
      return true;
    });
    return out;
  }
  // The name past those bounds, from the same sources in the order the
  // name computation takes them.
  function boundedName(el, roots, ctx) {
    const labelled = labelledTargets(el, ctx);
    if (labelled.length) return capName(normalize(labelled.map((t) => boundedNameText(t, ctx, true)).join(" ")));
    const label = cutAttr(el.getAttribute("aria-label"));
    if (normalize(label)) return capName(normalize(label));
    const fromRoots = roots.filter((r) => !labelled.includes(r)).map((r) => boundedNameText(r, ctx, true, r === el)).join(" ");
    if (normalize(fromRoots)) return capName(normalize(fromRoots));
    return capName(normalize(cutAttr(el.getAttribute("title") || el.getAttribute("alt") || el.getAttribute("placeholder"))));
  }

  function authorName(el, ctx) {
    const targets = ctx ? labelledTargets(el, ctx) : [];
    const labelled = targets.map((t) => boundedNameText(t, ctx)).join(" ");
    return capName(normalize(labelled || cutAttr(el.getAttribute("aria-label"))));
  }

  function nodeName(el, role, includeHidden, ctx) {
    if (AUTHOR_NAMED_ONLY_ROLES.has(role)) return authorName(el, ctx);
    if (ctx) {
      const roots = nameRoots(el, role, tagOf(el), ctx);
      if (!nameFits(el, roots, ctx)) return boundedName(el, roots, ctx);
    }
    return accessibleName(el, includeHidden);
  }

  function accessibleName(el, includeHidden) {
    if (!injected) return "";
    let name = injected.utils.getElementAccessibleName(el, !!includeHidden);
    // Playwright names by ARIA role, so a <div> that is a control here (an
    // editable or clickable one, a scroll region) gets its label attributes.
    if (!name && !el.getAttribute("role")) {
      const ids = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
      name = ids.map((id) => (el.ownerDocument.getElementById(id) || {}).textContent || "").join(" ") ||
        el.getAttribute("aria-label") || el.getAttribute("title") || "";
    }
    return capName(normalize(name));
  }

  // What a user can see. An element is *rendered* unless it or an ancestor
  // is display:none or content-visibility:hidden (a closed <details>,
  // hidden=until-found, which WebKit lays out as a block with skipped
  // content), inert, aria-hidden, or clipped away inside a zero-size box
  // with overflow hidden. A rendered element is *visible* when its own
  // visibility is `visible`; an invisible one can still hold visible
  // children. This is Playwright's isElementVisible (checkVisibility, which
  // Playwright skips on WebKit) without its non-empty box test, so an empty
  // progress bar or a zero-height float container still counts.
  function checkVisibility(el) {
    try {
      return typeof el.checkVisibility === "function" ? el.checkVisibility() : true;
    } catch {
      return true;
    }
  }
  const CLIPS = new Set(["hidden", "clip", "scroll", "auto"]);
  // content-visibility needs layout containment, which inline boxes and
  // table parts other than cells ignore.
  const NO_CONTAINMENT_DISPLAYS = new Set(["inline", "table-row", "table-row-group", "table-header-group",
    "table-footer-group", "table-column", "table-column-group", "ruby-base", "ruby-text", "contents"]);
  function skipsContents(style) {
    return style.contentVisibility === "hidden" && !NO_CONTAINMENT_DISPLAYS.has(style.display);
  }
  function isRendered(el, style) {
    if (!style || style.display === "none") return false;
    if (el.hasAttribute("inert")) return false;
    if (style.display === "contents") return true;
    if (!checkVisibility(el)) return false;
    if (CLIPS.has(style.overflowX) || CLIPS.has(style.overflowY)) {
      const r = el.getBoundingClientRect();
      if ((r.width < 1 && CLIPS.has(style.overflowX)) || (r.height < 1 && CLIPS.has(style.overflowY))) return false;
    }
    return true;
  }

  function hasPointerCursor(el, style) {
    if (!style || style.cursor !== "pointer") return false;
    const parent = parentCrossingShadow(el);
    const parentStyle = parent && styleOf(parent);
    return !(parentStyle && parentStyle.cursor === "pointer");
  }

  function isInteractive(el, role, style) {
    if (INTERACTIVE_ROLES.has(role) || role === "canvas") return true;
    const tag = tagOf(el);
    if (tag === "input") return (el.type || "").toLowerCase() !== "hidden";
    if (tag === "button" || tag === "select" || tag === "textarea" || tag === "summary") return true;
    if ((tag === "a" || tag === "area") && el.hasAttribute("href")) return true;
    if ((tag === "video" || tag === "audio") && el.hasAttribute("controls")) return true;
    if (isContentEditableHost(el)) return true;
    const tabindex = el.getAttribute("tabindex");
    if (tabindex !== null && Number(tabindex) >= 0) return true;
    if (el.hasAttribute("onclick") || el.getAttribute("draggable") === "true") return true;
    return hasPointerCursor(el, style);
  }

  function isScrollable(el, style) {
    const tag = tagOf(el);
    if (tag === "html" || tag === "body" || !style) return false;
    const scrolls = (v) => v === "auto" || v === "scroll" || v === "overlay";
    const y = scrolls(style.overflowY) && el.scrollHeight > el.clientHeight + 1;
    const x = scrolls(style.overflowX) && el.scrollWidth > el.clientWidth + 1;
    return x || y;
  }

  function isBlock(style, tag) {
    if (tag === "br") return true;
    const display = style ? style.display : "inline";
    return !!display && !display.startsWith("inline") && display !== "contents" && display !== "none";
  }

  function isDisabled(el) {
    try {
      if (el.matches(":disabled")) return true;
    } catch {}
    for (let cur = el; cur; cur = parentCrossingShadow(cur)) {
      if (cur.getAttribute("aria-disabled") === "true") return true;
    }
    return false;
  }

  function isUserInvalid(el) {
    try {
      return el.matches(":user-invalid");
    } catch {
      return false;
    }
  }

  // Whether the element or something inside it has a non-empty box that is
  // not clipped away (screen-reader-only text uses `clip` or `clip-path`).
  const clippedAway = (style) => !!style && ((style.clip && style.clip !== "auto") || (style.clipPath && style.clipPath !== "none"));
  // Each node it looks at inside is charged to the snapshot's budget; past
  // it the element counts as showing nothing (the snapshot stops there).
  function hasVisibleBox(el, ctx) {
    const r = el.getBoundingClientRect();
    if (r.width >= 1 && r.height >= 1) return true;
    // A zero-size box that clips its overflow shows none of its content.
    const style = styleOf(el);
    if (style && ((r.width < 1 && CLIPPING.has(style.overflowX)) || (r.height < 1 && CLIPPING.has(style.overflowY)))) return false;
    const range = document.createRange();
    const inside = (node) => {
      for (let n = node.firstChild; n; n = n.nextSibling) {
        if (!spend(ctx, 1)) return false;
        if (n.nodeType === 3) {
          if (!n.nodeValue.trim()) continue;
          range.selectNodeContents(n);
          const b = range.getBoundingClientRect();
          if (b.width >= 1 && b.height >= 1) return true;
        } else if (n.nodeType === 1) {
          const cs = styleOf(n);
          if (!cs || cs.display === "none" || clippedAway(cs)) continue;
          const b = n.getBoundingClientRect();
          if (b.width >= 1 && b.height >= 1) return true;
          if (inside(n)) return true;
        }
      }
      return false;
    };
    return inside(el);
  }

  // Whether a link goes to another site (hosts that differ after "www." and
  // ignoring subdomains of the same two-label base). The link's URL is sent
  // whole (displayUrl) and the snapshot renderer (snapshot.js) makes its
  // "host/first-segment/…" summary: secrets are masked natively by whole
  // value after the reply leaves the page, so a summary made here (or any
  // cut) could hand on part of a value.
  const siteOf = (host) => host.replace(/^www\./, "").split(".").slice(-2).join(".");
  const isOffsite = (url) => /^https?:$/.test(url.protocol) && !!global.location.hostname && siteOf(url.hostname) !== siteOf(global.location.hostname);

  // A link's URL, whole (snapshot.js drops an on-site link's origin and
  // caps it after masking), whether it is on the page's own origin, and
  // whether it goes to another site. The caller charges `href` to the
  // snapshot's size budget (fit), so a URL longer than the budget has left
  // is never resolved or parsed: its attribute, then its resolved form, is
  // handed on as written, for fit to charge and cut, and counts as neither
  // same-origin nor offsite.
  function displayUrl(el, ctx) {
    const raw = el.getAttribute("href");
    if (typeof raw === "string" && raw.length > ctx.sizeLeft) return /^\s*(javascript|data):/i.test(raw.slice(0, 64).replace(/[\t\n\r]/g, "")) ? null : { href: raw, sameOrigin: false, offsite: false };
    const href = el.href;
    if (!href || typeof href !== "string" || /^javascript:/i.test(href)) return null;
    if (href.length > ctx.sizeLeft) return /^data:/i.test(href) ? null : { href, sameOrigin: false, offsite: false };
    let url;
    try {
      url = new global.URL(href);
    } catch {
      return { href, sameOrigin: false, offsite: false };
    }
    if (url.protocol === "data:") return null;
    const sameOrigin = url.origin !== "null" && url.origin === global.location.origin;
    return { href: url.href, sameOrigin, offsite: !sameOrigin && isOffsite(url) };
  }

  // A value is charged to the snapshot's size budget by the caller; what
  // it reads is bounded here: an option label or ARIA value is cut before
  // it is normalized, and an editable element's text is read within what
  // the snapshot's budget has left (see boundedInnerText).
  function valueOf(el, role, tag, ctx) {
    if (tag === "input") {
      const type = (el.type || "").toLowerCase();
      if (NO_VALUE_INPUTS.has(type)) return null;
      if (type === "file") return el.files && el.files.length ? [...el.files].map((f) => f.name).join(", ") : null;
      if (type === "password") return el.value ? "********" : null;
      return el.value || null;
    }
    if (tag === "textarea") return el.value || null;
    if (tag === "select") {
      if (el.multiple || el.size > 1) return null;
      const option = el.options[el.selectedIndex];
      if (!option) return null;
      const label = option.getAttribute("label");
      return normalize(cutAttr(label) || (ctx ? boundedNameText(option, ctx) : cutAttr(option.textContent))) || null;
    }
    if (isContentEditableHost(el)) {
      if (!ctx) return normalize(el.innerText) || null;
      const b = readBudget({ maxNodes: Math.max(1, ctx.left), maxSize: Math.max(1, ctx.sizeLeft) });
      const text = boundedInnerText(el, b);
      spend(ctx, b.nodes - b.left);
      return normalize(text) || null;
    }
    if (tag === "progress" || tag === "meter") return el.hasAttribute("value") ? String(el.value) : null;
    if (VALUE_ROLES.has(role)) return cutAttr(el.getAttribute("aria-valuetext") || el.getAttribute("aria-valuenow")) || null;
    return null;
  }

  function applyStates(el, role, tag, node, ctx) {
    const type = tag === "input" ? (el.type || "").toLowerCase() : "";
    if (type === "checkbox" || type === "radio") {
      if (type === "checkbox" && el.indeterminate) node.checked = "mixed";
      else if (el.checked) node.checked = true;
    } else if (CHECKED_ROLES.has(role)) {
      const checked = (el.getAttribute("aria-checked") || "").toLowerCase();
      if (checked === "true") node.checked = true;
      else if (checked === "mixed") node.checked = "mixed";
    }
    if (node.act && isDisabled(el)) node.disabled = true;
    const expanded = el.getAttribute("aria-expanded");
    if (expanded === "true") node.expanded = true;
    else if (expanded === "false") node.expanded = false;
    else if (tag === "summary" && el.parentElement && tagOf(el.parentElement) === "details") node.expanded = !!el.parentElement.open;
    const pressed = (el.getAttribute("aria-pressed") || "").toLowerCase();
    if (pressed === "true") node.pressed = true;
    else if (pressed === "mixed") node.pressed = "mixed";
    if (tag === "option") {
      if (el.selected) node.selected = true;
    } else if (SELECTED_ROLES.has(role) && el.getAttribute("aria-selected") === "true") node.selected = true;
    if ((["input", "select", "textarea"].includes(tag) && el.required) || el.getAttribute("aria-required") === "true") node.required = true;
    const invalid = el.getAttribute("aria-invalid");
    if ((invalid && invalid !== "false") || isUserInvalid(el)) node.invalid = true;
    if (((tag === "input" && !NOT_READONLY_INPUTS.has(type)) || tag === "textarea") && el.readOnly) node.readonly = true;
    else if (el.getAttribute("aria-readonly") === "true") node.readonly = true;
    if (role === "heading") {
      const level = /^h[1-6]$/.test(tag) ? Number(tag[1]) : Number(el.getAttribute("aria-level")) || 2;
      node.level = level;
    } else if (el.hasAttribute("aria-level") && Number(el.getAttribute("aria-level")) >= 1) {
      node.level = Number(el.getAttribute("aria-level"));
    }
    if (ctx.focus === el) node.focused = true;
  }

  // The walk's bounds: a hostile page can hold millions of nodes (or make
  // each one slow to read), and the walk runs on the page's main thread
  // before any output limit applies. Past MAX_NODES visited nodes, or
  // MAX_WALK_MS of reading (under the host's 10 s frame timeout, so an
  // inner frame answers cut instead of timing out), the walk stops and the
  // host prints a note. The host can lower the node budget, never raise it.
  const MAX_NODES = 250000;
  const MAX_WALK_MS = 8000;
  // The node budget does not bound one node: one text node or field value
  // can hold megabytes, which would cross to the host and be kept and
  // diffed there. The walk also stops at MAX_SIZE characters of what it
  // returns (texts, names, values, URLs, and NODE_SIZE for each node's
  // keys); the string that passes it is cut ("size"). The host can lower
  // it, never raise it.
  const MAX_SIZE = 2000000;
  const NODE_SIZE = 32;
  const MAX_DEPTH = 1000;
  // The page-read budget: every read that sends page-controlled values to
  // the host (the snapshot walk and what it reads beside it, Markdown,
  // extraction, drop-down options, composer text) reads at most MAX_NODES
  // nodes and returns at most MAX_SIZE characters, for MAX_WALK_MS; past
  // any of them it stops and says why (`truncated`: "nodes", "size" or
  // "time"), and the host prints a note. A caller can lower a bound, never
  // raise it. `spend`, `chargeSize` and `fit` charge it.
  function readBudget(opts) {
    const o = opts || {};
    const nodes = Math.min(MAX_NODES, o.maxNodes > 0 ? Math.floor(o.maxNodes) : MAX_NODES);
    const size = Math.min(MAX_SIZE, o.maxSize > 0 ? Math.floor(o.maxSize) : MAX_SIZE);
    return { left: nodes, sizeLeft: size, nodes, size, deadline: now() + MAX_WALK_MS, ticks: 0, truncated: undefined };
  }
  // The budget for page functions the runtime runs in this world
  // (agent-tools.js): A.budget(opts).
  function budget(opts) {
    const b = readBudget(opts);
    return {
      spend: (count) => spend(b, count === undefined ? 1 : count),
      charge: (count) => chargeSize(b, count),
      fit: (s) => fit(b, s),
      // The characters left to charge, so a caller can refuse work (such as
      // parsing a URL) on a value fit would cut anyway.
      get sizeLeft() {
        return b.sizeLeft;
      },
      // `s` with its cuts settled, for a page function that cuts or
      // searches its own text before it replies (sealing settles the rest).
      settle: (s) => settleCuts(s),
      // The bounded DOM reads above, charged to this budget.
      textContent: (node) => boundedTextContent(node, b),
      innerText: (el) => boundedInnerText(el, b),
      outerHTML: (el) => boundedHTML(el, b, true),
      innerHTML: (el) => boundedHTML(el, b, false),
      get truncated() {
        return b.truncated;
      },
      // What the host needs for its note and for the budget it passes on.
      report: () => ({ visited: b.nodes - b.left, size: b.size - b.sizeLeft, maxNodes: b.nodes, maxSize: b.size, truncated: b.truncated }),
    };
  }
  // The reply budget. Every reply this world sends to the session passes
  // through `reply`: the runtime wraps each agent-world call in it
  // (runtime-core.js, Frame._call), so a method or page function added
  // here cannot reply around it. Past `limit` characters of JSON (at most
  // MAX_REPLY) the reply becomes a cut marker, which the runtime turns into
  // an error worded by core.readCutNote, as every read cut at its budget.
  // A caller can lower the limit, never raise it. The default is what a
  // read within the page-read budget can return: MAX_SIZE characters of
  // values and NODE_SIZE of keys for each of MAX_NODES nodes.
  const MAX_REPLY = MAX_SIZE + MAX_NODES * NODE_SIZE;
  const REPLY_CUT = "__cmuxReplyCut";
  // The reply of a method that stopped at its budget before it had all its
  // answer: the runtime fails the call with core.readCutNote's words, as
  // for a reply past the reply budget. `cut` is { truncated, maxNodes, maxSize }.
  const cutReply = (cut) => ({ [REPLY_CUT]: cut });
  // The characters of JSON `value` takes, counted until they pass `max`.
  // Iterative, and it stops there, so measuring costs at most the limit.
  function replySize(value, max) {
    let size = 0;
    const stack = [value];
    while (stack.length && size <= max) {
      const v = stack.pop();
      if (typeof v === "string") size += v.length + 2;
      else if (v === null || v === undefined || typeof v !== "object") size += typeof v === "function" ? 0 : 8;
      else if (Array.isArray(v)) {
        size += 2 + v.length;
        for (let i = 0; i < v.length && size <= max; i++) stack.push(v[i]);
      } else {
        size += 2;
        for (const key of Object.keys(v)) {
          size += key.length + 4;
          stack.push(v[key]);
          if (size > max) break;
        }
      }
    }
    return size;
  }
  // Settles every cut in `value`'s strings (settleCuts), in place.
  function settleReply(value) {
    if (typeof value === "string") return settleCuts(value);
    const stack = [value];
    while (stack.length) {
      const v = stack.pop();
      if (v === null || typeof v !== "object") continue;
      for (const key of Array.isArray(v) ? v.keys() : Object.keys(v)) {
        const item = v[key];
        if (typeof item === "string") {
          if (item.indexOf(CUT) !== -1) v[key] = settleCuts(item);
        } else if (item !== null && typeof item === "object") stack.push(item);
      }
    }
    return value;
  }
  function sealReply(value, limit) {
    const max = Math.min(MAX_REPLY, typeof limit === "number" && limit >= 0 ? Math.floor(limit) : MAX_REPLY);
    if (replySize(value, max) <= max) return settleReply(value);
    return cutReply({ truncated: "size", maxSize: max });
  }
  function reply(value, limit) {
    return value instanceof Promise ? value.then((v) => sealReply(v, limit)) : sealReply(value, limit);
  }
  // Reading the clock every node costs; every 256th is enough.
  function spend(ctx, count) {
    if (ctx.truncated) return false;
    if (ctx.left < count) {
      ctx.truncated = "nodes";
      return false;
    }
    ctx.left -= count;
    if (++ctx.ticks % 256 === 0 && now() > ctx.deadline) {
      ctx.truncated = "time";
      return false;
    }
    return true;
  }

  function chargeSize(ctx, count) {
    if (ctx.sizeLeft >= count) {
      ctx.sizeLeft -= count;
      return true;
    }
    ctx.sizeLeft = 0;
    if (!ctx.truncated) ctx.truncated = "size";
    return false;
  }
  // `s` charged to the size budget, cut where the budget ends (CUT, which
  // sealing turns into "…" well before the cut).
  function fit(ctx, s) {
    if (typeof s !== "string" || !s) return s;
    const left = ctx.sizeLeft;
    if (chargeSize(ctx, s.length)) return s;
    let end = left;
    // Never split a surrogate pair.
    if (end > 0 && /[\ud800-\udbff]/.test(s[end - 1])) end--;
    return s.slice(0, end) + CUT;
  }

  // ---------------------------------------------------------------------------
  // Bounded DOM reads. A DOM getter (textContent, innerText, outerHTML)
  // builds its whole string before anything can cut it, and a hostile
  // page sets how large that is. These read within a page-read budget `b`:
  // first a counting walk (nodes, and the lengths of the strings the getter
  // would join, read without copying them), stopped at what `b` has left;
  // when the getter's string fits, the getter runs and the string is
  // charged (exact text); else the string is built node by node and stops
  // where the budget does (`b.truncated` says why). Walks are iterative:
  // a page can nest elements deeper than the stack.
  const STOP = {};
  // Visits `root` and its descendants in tree order: enter(node) before a
  // node's children (false skips them, STOP ends the walk), leave(node)
  // after them. `templates`: a <template>'s content counts as its children.
  function walkTree(root, enter, leave, templates) {
    const outs = [];
    let n = root;
    for (;;) {
      const r = enter(n);
      if (r === STOP) return;
      let child = null;
      if (r !== false) {
        if (templates && n.nodeType === 1 && tagOf(n) === "template" && n.content) {
          child = n.content.firstChild;
          if (child) outs.push(n);
        } else child = n.firstChild;
      }
      if (child) {
        n = child;
        continue;
      }
      for (;;) {
        if (leave && leave(n) === STOP) return;
        if (n === root) return;
        if (n.nextSibling) {
          n = n.nextSibling;
          break;
        }
        let p = n.parentNode;
        if (outs.length && (!p || p === outs[outs.length - 1].content)) p = outs.pop();
        if (!p) return;
        n = p;
      }
    }
  }
  // What a getter of `kind` ("text": textContent, "inner": innerText,
  // "html": innerHTML/outerHTML) would read under `root`: { nodes, size,
  // depth } within `limits` ({ nodes, size, depth, deadline }), else
  // { over: "nodes" | "size" | "time" | "depth" }. Attributes count as
  // nodes; the size of HTML adds tags and attributes.
  function measureTree(root, kind, limits) {
    let nodes = 0;
    let size = 0;
    let depth = 0;
    let deepest = 0;
    let over = null;
    walkTree(root, (n) => {
      if (++nodes > limits.nodes) return (over = "nodes"), STOP;
      if ((nodes & 255) === 0 && now() > limits.deadline) return (over = "time"), STOP;
      const t = n.nodeType;
      if (t === 3 || t === 4) size += n.data.length;
      else if (t === 8 || t === 7) size += kind === "html" ? n.data.length + 7 : 0;
      else if (t === 1) {
        if (kind === "html") {
          const attrs = n.attributes;
          nodes += attrs.length;
          if (nodes > limits.nodes) return (over = "nodes"), STOP;
          size += 2 * n.tagName.length + 5;
          for (let i = 0; i < attrs.length; i++) size += attrs[i].name.length + attrs[i].value.length + 4;
        } else if (kind === "inner") size += 2;
        if (++depth > deepest) deepest = depth;
        if (deepest > limits.depth) return (over = "depth"), STOP;
      }
      if (size > limits.size) return (over = "size"), STOP;
      return kind === "html" || t === 1 || t === 9 || t === 11;
    }, (n) => {
      if (n.nodeType === 1) depth--;
    }, kind === "html");
    return over ? { over } : { nodes, size, depth: deepest };
  }
  // How far a getter's result may run past the counted size: escaping
  // grows HTML, innerText adds line breaks. A result past it is still cut.
  function readLimits(b) {
    return { nodes: b.left, size: b.sizeLeft, depth: Infinity, deadline: b.deadline };
  }
  // textContent: every Text descendant's data, in order.
  function boundedTextContent(node, b) {
    const t = node.nodeType;
    if (t === 3 || t === 4 || t === 7 || t === 8) return spend(b, 1) ? fit(b, node.data) : "";
    if (t === 9 || t === 10) return null;
    const m = measureTree(node, "text", readLimits(b));
    if (!m.over) {
      spend(b, m.nodes);
      return fit(b, node.textContent);
    }
    const parts = [];
    walkTree(node, (n) => {
      if (!spend(b, 1)) return STOP;
      if (n.nodeType === 3 || n.nodeType === 4) {
        parts.push(fit(b, n.data));
        if (b.truncated) return STOP;
      }
      return n.nodeType === 1 || n.nodeType === 11;
    });
    return parts.join("");
  }
  // innerText: past the budget, an approximation of the rendered text (no
  // hidden, script or style content; a line break around each block and
  // at each <br>) that stops at the budget.
  const NO_INNER_TEXT = new Set(["script", "style", "template", "noscript", "head", "title", "meta", "link"]);
  function boundedInnerText(el, b) {
    const m = measureTree(el, "inner", readLimits(b));
    if (!m.over) {
      spend(b, m.nodes);
      return fit(b, el.innerText);
    }
    const parts = [];
    const blocks = [];
    walkTree(el, (n) => {
      if (!spend(b, 1)) return STOP;
      if (n.nodeType === 3 || n.nodeType === 4) {
        parts.push(fit(b, n.data.replace(/[ \t\r\n]+/g, " ")));
        return b.truncated ? STOP : true;
      }
      if (n.nodeType !== 1) return false;
      const tag = tagOf(n);
      if (NO_INNER_TEXT.has(tag)) return false;
      if (tag === "br") {
        parts.push(fit(b, "\n"));
        return false;
      }
      const style = styleOf(n);
      if (!style || style.display === "none") return false;
      const block = n !== el && !/^inline/.test(style.display) && style.display !== "contents";
      if (block) parts.push(fit(b, "\n"));
      blocks.push(block);
      return true;
    }, (n) => {
      if (n.nodeType === 1 && n !== el && blocks.length && blocks.pop()) parts.push(fit(b, "\n"));
    });
    return parts.join("").replace(/ *\n */g, "\n").replace(/\n{3,}/g, "\n\n").replace(/^\n+|\n+$/g, "");
  }
  // innerHTML (`outer` false) or outerHTML: past the budget, the HTML
  // fragment serialization algorithm, node by node, stopped at the budget.
  const VOID_TAGS = new Set(["area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input", "keygen", "link", "meta", "param", "source", "track", "wbr"]);
  const RAW_TEXT_TAGS = new Set(["style", "script", "xmp", "iframe", "noembed", "noframes", "plaintext", "noscript"]);
  const FOREIGN_NS = new Set([HTML_NS, "http://www.w3.org/2000/svg", "http://www.w3.org/1998/Math/MathML"]);
  const escapeText = (s) => s.replace(/&/g, "&amp;").replace(/\u00a0/g, "&nbsp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const escapeAttr = (s) => s.replace(/&/g, "&amp;").replace(/\u00a0/g, "&nbsp;").replace(/"/g, "&quot;");
  function attrName(a) {
    if (!a.namespaceURI) return a.localName;
    if (a.namespaceURI === "http://www.w3.org/XML/1998/namespace") return "xml:" + a.localName;
    if (a.namespaceURI === "http://www.w3.org/2000/xmlns/") return a.localName === "xmlns" ? "xmlns" : "xmlns:" + a.localName;
    if (a.namespaceURI === "http://www.w3.org/1999/xlink") return "xlink:" + a.localName;
    return a.name;
  }
  function boundedHTML(el, b, outer) {
    const m = measureTree(el, "html", readLimits(b));
    if (!m.over) {
      spend(b, m.nodes);
      return fit(b, outer ? el.outerHTML : el.innerHTML);
    }
    const parts = [];
    const push = (s) => {
      parts.push(fit(b, s));
      return b.truncated ? STOP : true;
    };
    const tagName = (n) => (FOREIGN_NS.has(n.namespaceURI) ? n.localName : n.tagName);
    walkTree(el, (n) => {
      if (!spend(b, 1)) return STOP;
      if (n === el && !outer) return true;
      const t = n.nodeType;
      if (t === 3 || t === 4) {
        const p = n.parentNode;
        return push(p && p.nodeType === 1 && p.namespaceURI === HTML_NS && RAW_TEXT_TAGS.has(tagOf(p)) ? n.data : escapeText(n.data)) === STOP ? STOP : false;
      }
      if (t === 8) return push(`<!--${n.data}-->`) === STOP ? STOP : false;
      if (t === 7) return push(`<?${n.target} ${n.data}>`) === STOP ? STOP : false;
      if (t !== 1) return false;
      const attrs = n.attributes;
      if (!spend(b, attrs.length)) return STOP;
      let head = "<" + tagName(n);
      for (let i = 0; i < attrs.length; i++) head += ` ${attrName(attrs[i])}="${escapeAttr(attrs[i].value)}"`;
      if (push(head + ">") === STOP) return STOP;
      return !(n.namespaceURI === HTML_NS && VOID_TAGS.has(tagOf(n)));
    }, (n) => {
      if (n.nodeType !== 1 || (n === el && !outer)) return;
      if (n.namespaceURI === HTML_NS && VOID_TAGS.has(tagOf(n))) return;
      return push(`</${tagName(n)}>`);
    }, true);
    return parts.join("");
  }
  // A string read whole by the page (an attribute, a field's value),
  // charged and cut.
  function boundedString(s, b) {
    if (typeof s !== "string") return s;
    return spend(b, 1) ? fit(b, s) : "";
  }

  function visitNode(n, out, ctx, parentVisible, parentAriaHidden, skipText) {
    if (ctx.visited.has(n) || !spend(ctx, 1)) return;
    ctx.visited.add(n);
    if (n.nodeType === 3) {
      if ((parentVisible || ctx.showHidden) && !skipText && n.nodeValue) out.push(fit(ctx, n.nodeValue));
      return;
    }
    if (n.nodeType !== 1) return;
    // The walk recurses per element, and a page can nest elements deeper
    // than the stack (the HTML parser stops at 512, script does not): past
    // MAX_DEPTH the subtree is not read and a node with a ref says so.
    if (ctx.nest >= MAX_DEPTH) {
      out.push({ role: "generic", ref: refFor(n), unread: `nested deeper than ${MAX_DEPTH} elements; snapshot this ref to read it` });
      ctx.nestCut = true;
      return;
    }
    ctx.nest++;
    try {
      visitElement(n, out, ctx, parentAriaHidden, skipText);
    } finally {
      ctx.nest--;
    }
  }

  function visitChildren(el, out, ctx, visible, ariaHidden, skipText) {
    if (visible && !skipText) out.push(fit(ctx, pseudoText(el, "::before")));
    const assigned = tagOf(el) === "slot" ? el.assignedNodes() : [];
    if (assigned.length) {
      for (const child of assigned) {
        if (ctx.truncated) break;
        visitNode(child, out, ctx, visible, ariaHidden, skipText);
      }
    } else {
      for (let child = el.firstChild; child && !ctx.truncated; child = child.nextSibling) {
        if (!child.assignedSlot) visitNode(child, out, ctx, visible, ariaHidden, skipText);
      }
      if (el.shadowRoot) {
        for (let child = el.shadowRoot.firstChild; child && !ctx.truncated; child = child.nextSibling) visitNode(child, out, ctx, visible, ariaHidden, skipText);
      }
    }
    // Each id in aria-owns is charged, also one that names a node already
    // read: the page sets how many there are.
    const owns = el.getAttribute("aria-owns");
    if (owns) {
      const ids = /\S+/g;
      for (let m = ids.exec(owns); m && spend(ctx, 1); m = ids.exec(owns)) {
        const owned = el.ownerDocument.getElementById(m[0]);
        if (owned && owned !== el) visitNode(owned, out, ctx, visible, ariaHidden, skipText);
      }
    }
    if (visible && !skipText && !ctx.truncated) out.push(fit(ctx, pseudoText(el, "::after")));
  }

  // Clipping by overflow. An element that lies entirely outside the box of
  // an ancestor with `overflow: hidden|clip` (per axis) or `contain: paint`
  // cannot be seen (Amazon's overflowing nav belt, GitHub's ellipsized
  // commit links). Clips follow CSS containing blocks: an absolutely
  // positioned element escapes clippers below its nearest positioned
  // ancestor, a fixed one escapes all but those at or above a transformed
  // ancestor. The root and body clip the viewport, not a box, so they do not
  // count; scroll containers do not either (their content is reachable).
  const INTERACTIVE_SELECTOR = "a[href], area[href], button, input:not([type=hidden]), select, textarea, summary, " +
    "[tabindex]:not([tabindex='-1']), [contenteditable=''], [contenteditable=true], [role=button], [role=link], " +
    "[role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=option], [role=switch], [role=combobox], [role=textbox]";
  const CLIPPING = new Set(["hidden", "clip"]);
  const EMPTY_CLIPS = [];
  function clipRectOf(el, style) {
    const x = CLIPPING.has(style.overflowX);
    const y = CLIPPING.has(style.overflowY);
    const paint = /\b(paint|strict|content)\b/.test(style.contain || "");
    if (!x && !y && !paint) return null;
    const r = el.getBoundingClientRect();
    const left = r.left + el.clientLeft;
    const top = r.top + el.clientTop;
    return {
      left: x || paint ? left : -Infinity,
      right: x || paint ? left + (el.clientWidth || r.width) : Infinity,
      top: y || paint ? top : -Infinity,
      bottom: y || paint ? top + (el.clientHeight || r.height) : Infinity,
    };
  }
  // Counts the interactive elements in an offscreen subtree (viewport
  // snapshots say how many they leave out). The walk does not visit these,
  // so the count reads lazily and at most as many elements as the walk's
  // node budget, over the whole snapshot, and stops at its deadline; past
  // either the count is a lower bound (`offscreenMore`).
  function countOffscreen(el, ctx) {
    if (ctx.offscreenMore) return;
    const walker = el.ownerDocument.createTreeWalker(el, 1 /* NodeFilter.SHOW_ELEMENT */);
    for (let n = el; n; n = walker.nextNode()) {
      if (ctx.countLeft <= 0 || (++ctx.ticks % 256 === 0 && now() > ctx.deadline)) {
        ctx.offscreenMore = true;
        return;
      }
      ctx.countLeft--;
      if (n.matches(INTERACTIVE_SELECTOR)) ctx.offscreen++;
    }
  }
  const overlaps = (r, c) => r.right > c.left + 0.5 && r.left < c.right - 0.5 && r.bottom > c.top + 0.5 && r.top < c.bottom - 0.5;

  function visitElement(el, out, ctx, parentAriaHidden, skipText) {
    const tag = tagOf(el);
    if (SKIP_TAGS.has(tag)) return;
    const style = styleOf(el);
    if (!style || ctx.showHidden || style.display === "none") return visitElementBox(el, tag, style, out, ctx, parentAriaHidden, skipText);
    const saved = [ctx.clips, ctx.positioned, ctx.transformed];
    ctx.depth++;
    try {
      const position = style.position;
      if (position === "fixed") ctx.clips = ctx.clips.filter((c) => c.depth <= ctx.transformed);
      else if (position === "absolute") ctx.clips = ctx.clips.filter((c) => c.depth <= ctx.positioned);
      if ((ctx.clips.length || ctx.viewport) && style.display !== "contents") {
        const r = el.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) {
          for (const c of ctx.clips) {
            if (!overlaps(r, c.rect)) {
              out.push(DROPPED);
              return;
            }
          }
          if (ctx.viewport && !overlaps(r, ctx.viewport)) {
            countOffscreen(el, ctx);
            return;
          }
        }
      }
      const transform = style.transform !== "none" || style.filter !== "none" || /\b(paint|strict|content|layout)\b/.test(style.contain || "");
      if (position !== "static" || transform) ctx.positioned = ctx.depth;
      if (transform) ctx.transformed = ctx.depth;
      if (tag !== "html" && tag !== "body") {
        const rect = clipRectOf(el, style);
        if (rect) ctx.clips = ctx.clips.concat({ rect, depth: ctx.depth });
      }
      visitElementBox(el, tag, style, out, ctx, parentAriaHidden, skipText);
    } finally {
      ctx.depth--;
      [ctx.clips, ctx.positioned, ctx.transformed] = saved;
    }
  }

  function visitElementBox(el, tag, style, out, ctx, parentAriaHidden, skipText) {
    const ariaHidden = parentAriaHidden || el.getAttribute("aria-hidden") === "true";
    const rendered = !ariaHidden && isRendered(el, style);
    if (!rendered && !ctx.showHidden) return;
    const visible = rendered && style.visibility === "visible";
    // content-visibility:hidden keeps the element's box and skips its
    // contents, so nothing in it can be seen.
    if (rendered && !ctx.showHidden && skipsContents(style)) return;
    if (!visible && !ctx.showHidden) {
      // A visibility:hidden parent can still hold visible children.
      visitChildren(el, out, ctx, false, ariaHidden, skipText);
      return;
    }
    const role = roleOf(el);
    const interactive = isInteractive(el, role, style);
    const scrollable = isScrollable(el, style);
    // A hidden paragraph (showHidden) keeps its node so it can say [hidden].
    const flattens = FLATTEN_ROLES.has(role) && !(role === "paragraph" && !visible);
    const flattenable = flattens || FLATTEN_UNNAMED_ROLES.has(role);
    const name = flattens && !interactive && !scrollable ? "" : nodeName(el, role, !visible, ctx);
    if (!interactive && !scrollable && (flattens || (flattenable && !name))) {
      if (role === "img" || role === "image") return;
      // Unrendered content (showHidden) has no layout; keep it apart.
      const block = isBlock(style, tag) || !rendered;
      if (block) out.push(BREAK);
      // A <label>'s own text is its control's name, printed on the control.
      const labelText = tag === "label" && el.control;
      visitChildren(el, out, ctx, visible, ariaHidden, skipText || !!labelText);
      if (block) out.push(BREAK);
      return;
    }
    // A link or button with an empty box shows nothing unless some content
    // inside it has a box (Wikipedia's zero-width "Jump up" backlinks).
    if ((role === "link" || role === "button") && visible && !ctx.showHidden && !hasVisibleBox(el, ctx)) return;
    const node = { role };
    chargeSize(ctx, NODE_SIZE);
    if (name) node.name = fit(ctx, name);
    if (interactive || scrollable) node.act = 1;
    if (interactive || scrollable || role === "iframe" || (name && SCOPE_ROLES.has(role))) {
      node.ref = refFor(el);
      // On screen: the host keeps these when it condenses a large snapshot.
      if (visible && overlaps(el.getBoundingClientRect(), ctx.screen)) node.vp = 1;
    }
    if (!visible) node.hidden = 1;
    if (scrollable) node.scrollable = 1;
    applyStates(el, role, tag, node, ctx);
    if (role === "iframe") {
      node.frame = handleFor(el);
      if (ctx.focus === el) node.frameFocused = 1;
      delete node.focused;
      out.push(node);
      return;
    }
    const value = valueOf(el, role, tag, ctx);
    if (value !== null) node.value = fit(ctx, value);
    if (role === "link") {
      const url = displayUrl(el, ctx);
      if (url) {
        node.url = fit(ctx, url.href);
        if (url.sameOrigin) node.sameOrigin = 1;
        else if (url.offsite) node.offsite = 1;
      }
    }
    const placeholder = el.getAttribute("placeholder");
    if (placeholder && normalize(placeholder) !== name && (tag === "input" || tag === "textarea")) node.placeholder = fit(ctx, normalize(placeholder));
    if (tag === "select") {
      const optionName = (o) => (chargeSize(ctx, NODE_SIZE), fit(ctx, normalize(o.label || o.textContent)));
      const option = (o) => (o.selected ? { name: optionName(o), selected: true } : { name: optionName(o) });
      // A list box shows its options; a drop-down shows them on request. A
      // closed drop-down prints its first INLINE_OPTIONS and a count, so only
      // those cross to the host.
      // Options listed whole count toward the node budget; past it the
      // list stops.
      const listed = (map) => {
        const all = el.options;
        const list = [];
        for (let i = 0; i < all.length && !ctx.truncated && spend(ctx, 1); i++) list.push(map(all[i]));
        return list;
      };
      if (el.multiple || el.size > 1) node.children = listed((o) => Object.assign({ role: "option" }, option(o)));
      else if (ctx.allOptions || node.expanded === true) node.options = listed(option);
      else {
        const all = el.options;
        node.options = [];
        for (let i = 0; i < all.length && i < INLINE_OPTIONS && !ctx.truncated; i++) node.options.push(option(all[i]));
        if (all.length > INLINE_OPTIONS) node.optionCount = all.length;
      }
    }
    if (!LEAF_TAGS.has(tag) && !isContentEditableHost(el)) {
      const kids = [];
      visitChildren(el, kids, ctx, visible, ariaHidden, false);
      const children = normalizeChildren(kids);
      if (children.length) node.children = children;
    }
    out.push(node);
  }

  // Joins text between structural breaks and collapses whitespace to single
  // spaces, so inline markup never doubles a space.
  function normalizeChildren(items) {
    const out = [];
    let buffer = "";
    const flush = () => {
      const text = normalize(buffer);
      if (text) out.push(text);
      buffer = "";
    };
    let closeBracket = null;
    for (let item of items) {
      if (item === DROPPED) {
        // "(#1234)" with the link left out would read "()".
        const open = /[(\[]\s*$/.exec(buffer);
        if (open) {
          buffer = buffer.slice(0, open.index);
          closeBracket = open[0][0] === "(" ? ")" : "]";
        }
        continue;
      }
      if (typeof item === "string" && closeBracket) {
        const trimmed = item.replace(/^\s*/, "");
        if (trimmed[0] === closeBracket) item = trimmed.slice(1);
        closeBracket = null;
      } else if (item !== BREAK) closeBracket = null;
      if (typeof item === "string") buffer += item;
      else if (item === BREAK) buffer += "\n\u0000";
      else {
        flush();
        out.push(item);
      }
    }
    flush();
    // A break splits a text run into separate lines.
    return out.flatMap((c) => (typeof c === "string" ? c.split("\u0000").map(normalize).filter(Boolean) : [c]));
  }

  // opts: { root: handle | null, showHidden, base, maxNodes, maxSize } ->
  // { nodes, max, offscreen, ms, visited, size, truncated: "nodes" | "time" | "size" | undefined }
  const now = () => (global.performance && global.performance.now ? global.performance.now() : Date.now());
  function snapshot(opts) {
    return withReadCaches(() => readSnapshot(opts || {}));
  }
  function readSnapshot(opts) {
    const started = now();
    raiseRefBase(opts.base);
    pruneRefs();
    pruneHandles();
    const root = opts.root ? element(opts.root) : document.body || document.documentElement;
    if (!root || !root.isConnected) throw agentError("stale", "The snapshot root was removed from the page");
    const ctx = Object.assign(readBudget(opts), {
      showHidden: !!opts.showHidden,
      focus: deepActiveElement(document),
      visited: new Set(),
      depth: 0,
      // How deep the snapshot already is where this frame's tree goes (an
      // iframe's frame stitches under its iframe): the walk's depth bound
      // holds for the whole stitched tree, not for each frame alone.
      nest: Math.min(MAX_DEPTH, Math.max(0, Math.floor(Number(opts.nest)) || 0)),
      clips: EMPTY_CLIPS,
      positioned: -1,
      transformed: -1,
      viewport: opts.viewport ? { left: 0, top: 0, right: global.innerWidth, bottom: global.innerHeight } : null,
      screen: { left: 0, top: 0, right: global.innerWidth, bottom: global.innerHeight },
      allOptions: !!opts.options,
      offscreen: 0,
      countLeft: 0,
      offscreenMore: false,
    });
    ctx.countLeft = ctx.nodes;
    // The label index charges this snapshot's budget.
    labelBudget = ctx;
    const out = [];
    if (spend(ctx, 1)) visitElement(root, out, ctx, false, false);
    const nodes = normalizeChildren(out);
    // `ms` is the traversal time in this frame, for perf measurements.
    return { nodes, max: refCounter, doc: docToken, offscreen: ctx.offscreen, offscreenMore: ctx.offscreenMore || undefined, ms: now() - started, visited: ctx.nodes - ctx.left, size: ctx.size - ctx.sizeLeft, truncated: ctx.truncated };
  }

  // Table sizes, for leak checks (tests/browser-parity/perf).
  function stats() {
    return { refs: mapSize(refRegistry), handles: mapSize(handles) };
  }

  // `doc`: the token of the document that issued `ref` to the caller, when
  // it knows it. Refs restart in every document of a frame, and sessions that
  // share a tab number them from their own bases, so a ref a session got from
  // an earlier document can name a live element here; it is reported
  // `foreignDoc`, never live.
  function refState(ref, base, doc) {
    raiseRefBase(base);
    if (typeof doc === "string" && doc !== docToken) return { live: false, foreignDoc: true, max: refCounter, doc: docToken };
    return { live: !!refElement(ref), max: refCounter, doc: docToken };
  }

  function refForHandle(id, base) {
    raiseRefBase(base);
    return { ref: refFor(element(id)), max: refCounter, doc: docToken };
  }

  // The topmost element at a viewport point, raised to its nearest control,
  // scrollable region or iframe so the ref is something an agent can act on.
  function elementAt(x, y, base) {
    return withReadCaches(() => readElementAt(x, y, base));
  }
  function readElementAt(x, y, base) {
    raiseRefBase(base);
    let el = document.elementFromPoint(x, y);
    while (el && el.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) break;
      el = inner;
    }
    if (!el) return null;
    let target = el;
    for (let cur = el; cur && cur !== document.body && cur !== document.documentElement; cur = parentCrossingShadow(cur)) {
      const role = roleOf(cur);
      const style = styleOf(cur);
      if (role === "iframe" || isInteractive(cur, role, style) || isScrollable(cur, style)) {
        target = cur;
        break;
      }
    }
    if (roleOf(target) === "iframe") return { frame: handleFor(target), box: contentBox(handleFor(target)) };
    const r = target.getBoundingClientRect();
    return {
      ref: refFor(target),
      role: roleOf(target),
      name: accessibleName(target, false),
      box: { x: r.x, y: r.y, width: r.width, height: r.height },
      max: refCounter,
      doc: docToken,
    };
  }

  if (injected) {
    const engines = injected._engines;
    mapSet(engines, "aria-ref", Object.freeze({
      queryAll(root, selector) {
        // `e5@<token>`: the host checked the ref against this document's
        // token and pins the query to it, so a navigation between that check
        // and this query fails stale instead of matching the new document.
        const text = strTrim(StringOf(selector));
        const at = strIndexOf(text, "@");
        const ref = at < 0 ? text : strSlice(text, 0, at);
        if (at >= 0 && strSlice(text, at + 1) !== docToken) throw agentError("stale", PREVIOUS_DOCUMENT);
        const el = refElement(ref);
        return el ? [el] : [];
      },
    }));
    // The engine table answers through the built-ins as they were at
    // install, and keeps its engines (none is added after install).
    const own = (value) => ({ value, writable: false, enumerable: false, configurable: false });
    Object.defineProperties(engines, {
      get: own((name) => mapGet(engines, name)),
      has: own((name) => mapHas(engines, name)),
      set: own(() => engines),
      delete: own(() => false),
      clear: own(() => undefined),
    });
    Object.defineProperty(injected, "_engines", own(engines));
  }


  // ---------------------------------------------------------------------------
  // Selectors and element state

  function requireInjected() {
    if (!injected) throw agentError("unsupported", "Playwright injected script is not installed");
    return injected;
  }

  function splitFrames(selector) {
    const parsed = requireInjected().parseSelector(selector);
    const isEnterFrame = (p) => p.name === "internal:control" && p.body === "enter-frame";
    if (!parsed.parts.some(isEnterFrame)) return [selector];
    // A parsed part's `source` omits the engine name except for CSS.
    const text = (p) => (p.name === "css" ? p.source : `${p.name}=${p.source}`);
    const hops = [];
    let parts = [];
    for (const part of parsed.parts) {
      if (isEnterFrame(part)) {
        hops.push(parts.map(text).join(" >> "));
        parts = [];
      } else {
        parts.push(part);
      }
    }
    hops.push(parts.map(text).join(" >> "));
    return hops;
  }

  // Handles of the matches, the first `limit` when given: a handle is kept
  // in this world's table until its element goes, so a read that wants a
  // few of a page-sized match list keeps only those. It makes at most
  // MAX_NODES handles (the page-read node budget): past that, a call
  // without a limit is cut, and a limit above it keeps the first MAX_NODES.
  function queryAll(selector, scopeHandle, limit) {
    const inj = requireInjected();
    const root = scopeHandle ? element(scopeHandle) : document;
    const parsed = inj.parseSelector(selector);
    const found = withReadCaches(() => inj.querySelectorAll(parsed, root));
    const asked = Number.isInteger(limit) && limit >= 0;
    if (!asked && found.length > MAX_NODES) return cutReply({ truncated: "nodes", maxNodes: MAX_NODES });
    return found.slice(0, asked ? Math.min(limit, MAX_NODES) : MAX_NODES).map(handleFor);
  }

  function describe(id) {
    return requireInjected().previewNode(element(id));
  }

  function strictError(selector, ids) {
    return requireInjected().strictModeViolationError(requireInjected().parseSelector(selector), ids.map(element)).message;
  }

  // Playwright checks "stable" over animation frames. WebKit runs no
  // animation frames while a document is still loading (a body that never
  // ends), so after a quarter second without a frame the check samples the
  // element's box on timers instead: nothing renders, so nothing can move.
  async function checkStates(id, states) {
    const inj = requireInjected();
    const el = element(id);
    if (!states.includes("stable")) {
      const result = await inj.checkElementStates(el, states);
      return result === undefined ? "done" : result;
    }
    let frameSeen = false;
    global.requestAnimationFrame(() => (frameSeen = true));
    const viaFrames = inj.checkElementStates(el, states).then((r) => (r === undefined ? "done" : r));
    const fallback = new Promise((resolve) => global.setTimeout(resolve, 250)).then(async () => {
      if (frameSeen) return viaFrames;
      if (!el.isConnected) return "error:notconnected";
      const box = () => { const r = el.getBoundingClientRect(); return [r.x, r.y, r.width, r.height].join(","); };
      const first = box();
      await new Promise((resolve) => global.setTimeout(resolve, 50));
      if (!el.isConnected) return "error:notconnected";
      if (box() !== first) return { missingState: "stable" };
      const rest = states.filter((s) => s !== "stable");
      const result = rest.length ? await inj.checkElementStates(el, rest) : undefined;
      return result === undefined ? "done" : result;
    });
    return Promise.race([viaFrames, fallback]);
  }

  function elementState(id, state) {
    return requireInjected().elementState(element(id), state);
  }

  function isInViewport(rect) {
    return rect.top >= 0 && rect.left >= 0 && rect.bottom <= global.innerHeight && rect.right <= global.innerWidth;
  }

  // True when a scroll container between the element and the viewport cuts
  // part of it off (a target inside a nested scroller).
  function clippedByScroller(el, rect) {
    for (let p = el.parentElement || (el.getRootNode() && el.getRootNode().host); p && p !== document.documentElement && p !== document.body; p = p.parentElement || (p.getRootNode() && p.getRootNode().host)) {
      if (p.scrollHeight <= p.clientHeight && p.scrollWidth <= p.clientWidth) continue;
      const cs = global.getComputedStyle(p);
      if (!/(auto|scroll|hidden|clip)/.test(cs.overflowX + " " + cs.overflowY)) continue;
      const r = p.getBoundingClientRect();
      if (rect.top < r.top - 0.5 || rect.bottom > r.bottom + 0.5 || rect.left < r.left - 0.5 || rect.right > r.right + 0.5) return true;
    }
    return false;
  }

  function scrollIntoViewIfNeeded(id) {
    const el = element(id);
    if (!el.isConnected) return "error:notconnected";
    const rect = el.getBoundingClientRect();
    if (isInViewport(rect) && !clippedByScroller(el, rect)) return "done";
    if (typeof el.scrollIntoViewIfNeeded === "function") el.scrollIntoViewIfNeeded(true);
    else el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    return "done";
  }

  function rectOf(id) {
    const el = element(id);
    if (!el.isConnected) return null;
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  }

  // Center of the first client rect that is visible in the viewport, as
  // Playwright picks the first clipped content quad.
  function clickPoint(id) {
    const el = element(id);
    if (!el.isConnected) return { error: "error:notconnected" };
    const w = global.innerWidth;
    const h = global.innerHeight;
    const rects = [...el.getClientRects()].filter((r) => r.width > 0 && r.height > 0);
    if (!rects.length) return { error: "error:notvisible" };
    for (const r of rects) {
      const left = Math.max(r.left, 0);
      const top = Math.max(r.top, 0);
      const right = Math.min(r.right, w);
      const bottom = Math.min(r.bottom, h);
      if (right - left > 0.99 && bottom - top > 0.99) return { x: (left + right) / 2, y: (top + bottom) / 2 };
    }
    return { error: "error:notinviewport" };
  }

  function hitTarget(id, point, behavior) {
    const inj = requireInjected();
    const el = inj.retarget(element(id), behavior || "button-link");
    if (!el || !el.isConnected) return "error:notconnected";
    const result = inj.expectHitTarget(point, el);
    return result === "done" ? "done" : result.hitTargetDescription;
  }

  // Chromium moves focus to a focusable element on mousedown; WebKit on macOS
  // does not focus buttons or links. The runtime calls this between mousedown
  // and mouseup so focus follows the Chromium (reference) model.
  function emulateClickFocus(id, before) {
    const el = element(id);
    if (!el.isConnected) return false;
    const doc = el.ownerDocument;
    const active = doc.activeElement;
    if (before !== undefined && active !== (before ? handleElement(before) : doc.body) && active !== doc.body) return false;
    const target = el.closest("button, a[href], summary, input, select, textarea, [tabindex], [contenteditable=true], iframe");
    if (!target || target === active) return false;
    if (target.matches(":disabled")) return false;
    target.focus({ preventScroll: true });
    return doc.activeElement === target;
  }

  // The file input whose click (user, driver or page script `input.click()`)
  // most recently happened; WebKit does not say which input opened a chooser,
  // and `document.activeElement` is the button when a page opens a hidden input.
  let lastFileInput = null;
  document.addEventListener(
    "click",
    (event) => {
      const target = event.target;
      if (target instanceof HTMLInputElement && target.type === "file") lastFileInput = target;
    },
    true,
  );

  // The element that opened the current file chooser: the last clicked file
  // input while it is connected, else the focused element.
  function chooserHandle() {
    if (lastFileInput && lastFileInput.isConnected) return handleFor(lastFileInput);
    return activeHandle();
  }

  function activeHandle() {
    const active = document.activeElement;
    return active && active !== document.body ? handleFor(active) : null;
  }

  function fill(id, value) {
    return requireInjected().fill(element(id), value);
  }
  function selectText(id) {
    return requireInjected().selectText(element(id));
  }
  function focus(id, resetSelection) {
    return requireInjected().focusNode(element(id), resetSelection);
  }
  function blur(id) {
    return requireInjected().blurNode(element(id));
  }
  function selectOptions(id, options) {
    const inj = requireInjected();
    const resolved = options.map((o) => (o && o.handle ? element(o.handle) : o));
    return inj.selectOptions(element(id), resolved);
  }
  function dispatchEvent(id, type, init) {
    requireInjected().dispatchEvent(element(id), type, init || {});
    return "done";
  }
  function retargetHandle(id, behavior) {
    const el = requireInjected().retarget(element(id), behavior);
    return el ? handleFor(el) : null;
  }

  function read(id, what, arg) {
    const el = element(id);
    switch (what) {
      case "textContent":
        return el.textContent;
      case "innerText":
        if (!(el instanceof global.HTMLElement)) throw agentError("invalid", "Node is not an HTMLElement");
        return el.innerText;
      case "innerHTML":
        return el.innerHTML;
      case "getAttribute":
        return el.getAttribute(arg);
      case "inputValue": {
        const target = requireInjected().retarget(el, "follow-label");
        const tag = target ? tagOf(target) : "";
        if (!["input", "textarea", "select"].includes(tag)) {
          throw agentError("invalid", "Node is not an <input>, <textarea> or <select> element");
        }
        return target.value;
      }
      case "tagName":
        return el.tagName;
      case "isFileInput":
        return tagOf(el) === "input" && (el.type || "").toLowerCase() === "file";
      case "multiple":
        return !!el.multiple;
      case "composerText":
        return composerText(el, arg);
      default:
        throw agentError("invalid", `Unknown read ${what}`);
    }
  }

  // A locator's string read within one page-read budget: { value, cut }
  // with `cut` the budget's report when it stopped the read.
  function readBounded(id, what, arg) {
    const el = element(id);
    const b = readBudget();
    let value;
    switch (what) {
      case "textContent":
        value = boundedTextContent(el, b);
        break;
      case "innerText":
        if (!(el instanceof global.HTMLElement)) throw agentError("invalid", "Node is not an HTMLElement");
        value = boundedInnerText(el, b);
        break;
      case "innerHTML":
        value = boundedHTML(el, b, false);
        break;
      case "outerHTML":
        value = boundedHTML(el, b, true);
        break;
      case "getAttribute":
        value = boundedString(el.getAttribute(arg), b);
        break;
      case "inputValue":
        value = boundedString(read(id, "inputValue"), b);
        break;
      default:
        throw agentError("invalid", `Unknown read ${what}`);
    }
    return { value, cut: b.truncated ? { truncated: b.truncated, maxNodes: b.nodes, maxSize: b.size } : null };
  }
  // The same read of several elements (allTextContents, allInnerTexts),
  // all within one budget: { values, cut }; elements past it read "".
  function readAllBounded(ids, what) {
    const b = readBudget();
    const values = [];
    for (const id of ids) {
      const el = element(id);
      if (b.truncated) values.push("");
      else if (what === "innerText") values.push(el instanceof global.HTMLElement ? boundedInnerText(el, b) : boundedTextContent(el, b) || "");
      else values.push(boundedTextContent(el, b) || "");
    }
    return { values, cut: b.truncated ? { truncated: b.truncated, maxNodes: b.nodes, maxSize: b.size } : null };
  }
  // The document's HTML (doctype and outerHTML of its root) within one
  // page-read budget, for page.content().
  function documentHTML() {
    const b = readBudget();
    const doctype = document.doctype ? fit(b, new global.XMLSerializer().serializeToString(document.doctype)) : "";
    const value = doctype + (document.documentElement ? boundedHTML(document.documentElement, b, true) : "");
    return { value, cut: b.truncated ? { truncated: b.truncated, maxNodes: b.nodes, maxSize: b.size } : null };
  }

  // All the text a composer will send: a field's value, else every text
  // node in it, hidden ones too (they are sent), with a space at each block
  // boundary and line break, read in this world (a page script cannot
  // change what it returns). Elements matching `exclude` (the site's own
  // signature or quoted text) are left out. Sites compare it whole with the
  // confirmed draft before a public send.
  const BLOCK_TAGS = new Set(["address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt", "figcaption", "figure",
    "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "td",
    "th", "tr", "ul"]);
  // The text is read within the page-read budget and never cut: a cut text
  // could not be compared whole, so past the budget the read fails in the
  // page and nothing crosses to the host.
  function composerText(el, exclude) {
    const b = readBudget();
    const tooLarge = () => {
      if (b.truncated === "nodes") return agentError("invalid", "The composer holds too many nodes to compare");
      if (b.truncated === "time") return agentError("invalid", "The composer took too long to read to compare");
      return agentError("invalid", `The composer holds more than ${String(MAX_SIZE).replace(/\B(?=(\d{3})+(?!\d))/g, ",")} characters, more than cmux compares with a draft`);
    };
    const add = (s) => {
      if (!chargeSize(b, s.length)) throw tooLarge();
      out += s;
    };
    const tag = tagOf(el);
    if (tag === "textarea" || tag === "input") {
      const value = el.value;
      if (!chargeSize(b, value.length)) throw tooLarge();
      return value;
    }
    let out = "";
    const walk = (node) => {
      for (let n = node.firstChild; n; n = n.nextSibling) {
        if (!spend(b, 1)) throw tooLarge();
        if (n.nodeType === 3) add(n.nodeValue);
        else if (n.nodeType === 1) {
          if (exclude && n.matches(exclude)) {
            add(" ");
            continue;
          }
          const block = BLOCK_TAGS.has(tagOf(n));
          if (block) add(" ");
          walk(n);
          if (block) add(" ");
        }
      }
    };
    walk(el);
    return out;
  }

  // This frame's place in its parent's window.frames, or -1 (the main
  // frame, or a frame the parent does not list: WebKit leaves out frames in
  // shadow trees). Only the engine's window objects are read.
  function framePosition() {
    const p = window.parent;
    if (!p || p === window) return -1;
    const length = p.length;
    for (let i = 0; i < length; i++) if (p[i] === window) return i;
    return -1;
  }

  // Candidates for the <iframe> (or <frame>) that shows the child frame at
  // `position` in window.frames (framePosition() in the child), as handles,
  // which the caller confirms with the driver: the light-DOM element whose
  // window is that one; else (a frame in a shadow tree) the frames in
  // shadow trees, found by a walk of the elements. Both count against one
  // budget of at most MAX_NODES (the snapshot's), as the page sets their
  // number: each light-DOM <iframe> and <frame> checked (read one at a time
  // from the document's live collections, never listed whole), then each
  // element walked. `truncated` says the lookup stopped at the budget.
  function iframeHandles(position, maxNodes) {
    const target = Number.isInteger(position) && position >= 0 && position < window.length ? window[position] : null;
    let left = Math.min(MAX_NODES, maxNodes > 0 ? Math.floor(maxNodes) : MAX_NODES);
    if (target) {
      for (const tag of ["iframe", "frame"]) {
        const owners = document.getElementsByTagName(tag);
        for (let i = 0, el = owners[0]; el; el = owners[++i]) {
          if (--left < 0) return { handles: [], truncated: true };
          if (el.contentWindow === target) return { handles: [handleFor(el)], truncated: false };
        }
      }
    }
    let truncated = false;
    const out = [];
    const roots = [document];
    while (roots.length && !truncated) {
      const root = roots.pop();
      const walker = document.createTreeWalker(root, 1);
      for (let el = walker.nextNode(); el; el = walker.nextNode()) {
        if (--left < 0) {
          truncated = true;
          break;
        }
        if (root !== document) {
          const tag = tagOf(el);
          if ((tag === "iframe" || tag === "frame") && (!target || el.contentWindow === target)) out.push(handleFor(el));
        }
        if (el.shadowRoot) roots.push(el.shadowRoot);
      }
    }
    return { handles: out, truncated };
  }

  // Content box of an <iframe> in this frame's viewport coordinates.
  function contentBox(id) {
    const el = element(id);
    const r = el.getBoundingClientRect();
    const cs = styleOf(el);
    const px = (v) => parseFloat(v) || 0;
    const left = r.left + el.clientLeft + px(cs && cs.paddingLeft);
    const top = r.top + el.clientTop + px(cs && cs.paddingTop);
    const width = el.clientWidth - px(cs && cs.paddingLeft) - px(cs && cs.paddingRight);
    const height = el.clientHeight - px(cs && cs.paddingTop) - px(cs && cs.paddingBottom);
    return { x: left, y: top, width, height };
  }

  // Why the frame an <iframe> shows is not simply its content box moved in
  // this viewport, or null. The runtime adds the box's position to a point
  // in the frame; a scale, rotation, skew, zoom, perspective or motion path
  // on the <iframe> or on an ancestor in the flat tree (the layout's
  // ancestors, through slots and shadow hosts), or an SVG drawing around
  // it, maps that point elsewhere, and the trusted input would land there.
  // A translation keeps the sum right: getBoundingClientRect has it.
  const SVG_NS = "http://www.w3.org/2000/svg";
  function translationOnly(transform) {
    if (!transform || transform === "none") return true;
    const m = /^matrix(3d)?\(([^)]*)\)$/.exec(transform.trim());
    if (!m) return false;
    const v = m[2].split(",").map(Number);
    if (v.some((n) => !Number.isFinite(n))) return false;
    // matrix(a, b, c, d, e, f): a = d = 1, b = c = 0. matrix3d: the identity
    // except m41 and m42 (16 values, column-major).
    if (!m[1]) return v.length === 6 && v[0] === 1 && v[1] === 0 && v[2] === 0 && v[3] === 1;
    const identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, null, null, 0, 1];
    return v.length === 16 && identity.every((want, i) => want === null || v[i] === want);
  }
  function geometryChange(el) {
    for (let e = el; e; ) {
      if (e.namespaceURI === SVG_NS) return `<${tagOf(e)}> (an SVG drawing) holds it`;
      const cs = styleOf(e);
      if (cs) {
        const set = (v) => v && v !== "none";
        const zoom = cs.zoom;
        let what = null;
        if (!translationOnly(cs.transform)) what = `transform: ${cs.transform}`;
        else if (set(cs.rotate)) what = `rotate: ${cs.rotate}`;
        else if (set(cs.scale) && !/^1( 1){0,2}$/.test(cs.scale)) what = `scale: ${cs.scale}`;
        else if (zoom && zoom !== "normal" && Number(zoom) !== 1) what = `zoom: ${zoom}`;
        else if (set(cs.perspective)) what = `perspective: ${cs.perspective}`;
        else if (set(cs.offsetPath)) what = `offset-path: ${cs.offsetPath}`;
        if (what) return `<${tagOf(e)}>${e === el ? "" : " around it"} has ${what.length > 120 ? what.slice(0, 119) + "…" : what}`;
      }
      const parent = e.assignedSlot || e.parentNode;
      e = parent && parent.nodeType === 11 ? parent.host || null : parent && parent.nodeType === 1 ? parent : null;
    }
    return null;
  }

  // Where `point` of the frame <iframe> `id` shows lies in this frame's
  // viewport: { x, y }, with `hit` (when `check`) "done" or the element of
  // this frame that the point would reach instead of the <iframe>.
  // { transformed } names the geometry that makes the point unknown.
  function ownerPoint(id, point, check) {
    const el = element(id);
    if (!el.isConnected) return { error: "error:notconnected" };
    const transformed = geometryChange(el);
    if (transformed) return { transformed };
    const box = contentBox(id);
    const at = { x: box.x + point.x, y: box.y + point.y };
    if (check) at.hit = hitTarget(id, at, "none");
    return at;
  }

  // Whether a press at `at` of this frame's viewport reaches what the
  // runtime checked: the element `id`, or (with `from`, the press's point
  // in the frame it shows) the <iframe> `id` with that point mapping to
  // `at`. The driver calls it right before it sends the press, after the
  // page has run since the runtime's own check. Returns null, or why not.
  function pressCheck(id, at, from) {
    try {
      if (from) {
        const r = ownerPoint(id, from, true);
        if (r.error) return "the frame's <iframe> was detached from the DOM";
        if (r.transformed) return `the frame's <iframe> is transformed (${r.transformed})`;
        if (r.hit !== "done") return `${r.hit} intercepts pointer events`;
        if (r.x !== at.x || r.y !== at.y) return "the frame's <iframe> moved";
        return null;
      }
      const hit = hitTarget(id, at, "button-link");
      if (hit === "done") return null;
      return hit === "error:notconnected" ? "the element was detached from the DOM" : `${hit} intercepts pointer events`;
    } catch (e) {
      return String((e && e.message) || e);
    }
  }

  // ---------------------------------------------------------------------------
  // Annotated screenshots: boxes and labels in a closed shadow root that is
  // removed right after capture. `refs` are [localRef, label] pairs that
  // the document `doc` (its token) issued; another document's refs are
  // never drawn, also when their numbers exist here.

  let overlay = null;
  function annotate(refs, doc) {
    clearAnnotations();
    if (doc !== docToken) return 0;
    const host = document.createElement("cmux-annotations");
    host.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483647;display:block";
    const root = host.attachShadow({ mode: "closed" });
    let drawn = 0;
    for (const [ref, label] of refs) {
      const el = refElement(ref);
      if (!el) continue;
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      if (r.bottom < 0 || r.right < 0 || r.top > global.innerHeight || r.left > global.innerWidth) continue;
      const box = document.createElement("div");
      box.style.cssText = `position:fixed;left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px;` +
        "border:2px solid #e5007a;box-sizing:border-box";
      const tag = document.createElement("div");
      tag.textContent = label;
      tag.style.cssText = `position:fixed;left:${r.left}px;top:${Math.max(0, r.top - 14)}px;background:#e5007a;` +
        "color:#fff;font:bold 10px/14px monospace;padding:0 3px";
      root.append(box, tag);
      drawn++;
    }
    (document.body || document.documentElement).appendChild(host);
    overlay = host;
    return drawn;
  }
  function clearAnnotations() {
    if (overlay) overlay.remove();
    overlay = null;
    return "done";
  }

  const agent = {
    version: 2,
    ping: () => "pong",
    handleFor,
    element,
    snapshot,
    stats,
    refState,
    refForHandle,
    elementAt,
    splitFrames,
    queryAll,
    describe,
    strictError,
    checkStates,
    elementState,
    scrollIntoViewIfNeeded,
    rect: rectOf,
    clickPoint,
    hitTarget,
    emulateClickFocus,
    activeHandle,
    chooserHandle,
    fill,
    selectText,
    focus,
    blur,
    selectOptions,
    dispatchEvent,
    retarget: retargetHandle,
    read,
    readBounded,
    readAllBounded,
    documentHTML,
    framePosition,
    iframeHandles,
    contentBox,
    ownerPoint,
    pressCheck,
    annotate,
    clearAnnotations,
    budget,
    reply,
  };
  // Frozen and permanent: other code in this world cannot replace a method
  // or the agent itself (see the top of this file).
  Object.defineProperty(global, KEY, { value: Object.freeze(agent), enumerable: false, configurable: false, writable: false });
  // The Swift driver resolves handles for input.setFiles through this name.
  Object.defineProperty(global, "__cmuxPageAgent", {
    value: Object.freeze({ resolveHandle: (id) => handleElement(id) }),
    enumerable: false,
    configurable: false,
    writable: false,
  });
})(
  globalThis,
  typeof __cmuxInjectedScriptFactory !== "undefined" ? __cmuxInjectedScriptFactory : null,
  // Playwright's role, name and hidden-state caches (its own snapshot and
  // getByRole turn them on while the DOM cannot change). The install recipe
  // puts the injected script's top-level functions in this scope.
  typeof beginAriaCaches === "function" && typeof endAriaCaches === "function" ? { begin: beginAriaCaches, end: endAriaCaches } : null,
);
