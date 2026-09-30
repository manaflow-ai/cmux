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
(function (global, injectedFactory) {
  "use strict";
  const KEY = Symbol.for("cmux.browserRepl.agent");
  if (global[KEY]) return;

  const document = global.document;

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
      configurable: true,
      enumerable: shadowRootDescriptor.enumerable,
      get() {
        const root = read.call(this);
        if (!root) return null;
        const name = this.localName || "";
        return this.namespaceURI === HTML_NS && (name.includes("-") || AUTHOR_SHADOW_HOSTS.has(name)) ? root : null;
      },
    });
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

  let nextHandle = 1;
  const handleOf = new WeakMap();
  const handles = new Map();
  function handleFor(el) {
    let id = handleOf.get(el);
    if (!id) {
      id = "h" + nextHandle++;
      handleOf.set(el, id);
    }
    handles.set(id, el);
    return id;
  }
  function element(id) {
    const el = handles.get(id);
    if (!el) throw agentError("stale", "Element handle is no longer available");
    return el;
  }
  function agentError(code, message) {
    const e = new Error(message);
    e.code = code;
    return e;
  }

  const tagOf = (el) => (el.localName || el.tagName || "").toLowerCase();
  const styleOf = (el, pseudo) => {
    try {
      return global.getComputedStyle(el, pseudo || null);
    } catch {
      return null;
    }
  };
  const normalize = (s) => String(s || "").replace(/\s+/g, " ").trim();
  // A safety cap only: the host decides how much of a name to print.
  const capName = (s) => (s.length > 2000 ? s.slice(0, 1999) + "…" : s);

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
  // so numbering continues after the frame loads a new document.

  const refOf = new WeakMap();
  const refRegistry = new Map();
  let refCounter = 0;
  const weak = typeof global.WeakRef === "function" ? (el) => new global.WeakRef(el) : (el) => ({ deref: () => el });

  function raiseRefBase(base) {
    if (typeof base === "number" && base > refCounter) refCounter = base;
  }
  function refFor(el) {
    let ref = refOf.get(el);
    if (!ref) {
      ref = "e" + ++refCounter;
      refOf.set(el, ref);
      refRegistry.set(ref, weak(el));
    }
    return ref;
  }
  function refElement(ref) {
    const entry = refRegistry.get(ref);
    const el = entry && entry.deref();
    return el && el.isConnected ? el : null;
  }
  function pruneRefs() {
    for (const [ref, entry] of refRegistry) if (!entry.deref()) refRegistry.delete(ref);
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
  const layoutTables = new WeakMap();
  const TABLE_PART_TAGS = new Set(["table", "thead", "tbody", "tfoot", "tr", "td", "th"]);
  function isLayoutTable(table) {
    let layout = layoutTables.get(table);
    if (layout !== undefined) return layout;
    layout = false;
    if (!table.getAttribute("role") && !table.hasAttribute("summary") && !(Number(table.getAttribute("border")) > 0) &&
        !(table.caption || table.tHead || table.tFoot || table.querySelector(":scope > colgroup"))) {
      const rows = [...table.rows];
      let dataCell = false;
      const lengths = new Set();
      for (const row of rows) {
        let length = 0;
        for (const cell of row.cells) {
          length += cell.colSpan || 1;
          if (tagOf(cell) === "th" || cell.hasAttribute("scope") || cell.hasAttribute("headers") || cell.getAttribute("role")) dataCell = true;
        }
        if (length) lengths.add(length);
      }
      if (!dataCell) {
        const columns = Math.max(0, ...lengths);
        const nested = !!table.querySelector("table") || !!(table.parentElement && table.parentElement.closest("td, th"));
        layout = nested || rows.length <= 1 || columns <= 1 || lengths.size > 1;
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

  function authorName(el) {
    const ids = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
    const labelled = ids.map((id) => (el.ownerDocument.getElementById(id) || {}).textContent || "").join(" ");
    return capName(normalize(labelled || el.getAttribute("aria-label") || ""));
  }

  function nodeName(el, role, includeHidden) {
    if (AUTHOR_NAMED_ONLY_ROLES.has(role)) return authorName(el);
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
  function hasVisibleBox(el) {
    const r = el.getBoundingClientRect();
    if (r.width >= 1 && r.height >= 1) return true;
    // A zero-size box that clips its overflow shows none of its content.
    const style = styleOf(el);
    if (style && ((r.width < 1 && CLIPPING.has(style.overflowX)) || (r.height < 1 && CLIPPING.has(style.overflowY)))) return false;
    const range = document.createRange();
    const inside = (node) => {
      for (let n = node.firstChild; n; n = n.nextSibling) {
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

  // "host/first-segment/…" for a link to another site (hosts that differ
  // after "www." and ignoring subdomains of the same two-label base), capped.
  const siteOf = (host) => host.replace(/^www\./, "").split(".").slice(-2).join(".");
  function offsiteSummary(el) {
    const href = el.href;
    if (!href || typeof href !== "string") return null;
    let url;
    try {
      url = new global.URL(href);
    } catch {
      return null;
    }
    if (!/^https?:$/.test(url.protocol) || !global.location.hostname) return null;
    if (siteOf(url.hostname) === siteOf(global.location.hostname)) return null;
    const segments = url.pathname.split("/").filter(Boolean);
    let out = url.hostname.replace(/^www\./, "") + (segments.length ? "/" + segments[0] : "");
    if (segments.length > 1 || url.search) out += "/…";
    return out.length > 48 ? out.slice(0, 47) + "…" : out;
  }

  function displayUrl(el) {
    const href = el.href;
    if (!href || typeof href !== "string" || /^javascript:/i.test(href)) return null;
    let url;
    try {
      url = new global.URL(href);
    } catch {
      return href;
    }
    if (url.protocol === "data:") return null;
    if (url.origin !== "null" && url.origin === global.location.origin) return url.pathname + url.search + url.hash;
    return url.href.length > 300 ? url.href.slice(0, 299) + "…" : url.href;
  }

  function valueOf(el, role, tag) {
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
      return option ? normalize(option.label || option.textContent) || null : null;
    }
    if (isContentEditableHost(el)) return normalize(el.innerText) || null;
    if (tag === "progress" || tag === "meter") return el.hasAttribute("value") ? String(el.value) : null;
    if (VALUE_ROLES.has(role)) return el.getAttribute("aria-valuetext") || el.getAttribute("aria-valuenow") || null;
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

  function visitNode(n, out, ctx, parentVisible, parentAriaHidden, skipText) {
    if (ctx.visited.has(n)) return;
    ctx.visited.add(n);
    if (n.nodeType === 3) {
      if ((parentVisible || ctx.showHidden) && !skipText && n.nodeValue) out.push(n.nodeValue);
      return;
    }
    if (n.nodeType === 1) visitElement(n, out, ctx, parentAriaHidden, skipText);
  }

  function visitChildren(el, out, ctx, visible, ariaHidden, skipText) {
    if (visible && !skipText) out.push(pseudoText(el, "::before"));
    const assigned = tagOf(el) === "slot" ? el.assignedNodes() : [];
    if (assigned.length) {
      for (const child of assigned) visitNode(child, out, ctx, visible, ariaHidden, skipText);
    } else {
      for (let child = el.firstChild; child; child = child.nextSibling) {
        if (!child.assignedSlot) visitNode(child, out, ctx, visible, ariaHidden, skipText);
      }
      if (el.shadowRoot) {
        for (let child = el.shadowRoot.firstChild; child; child = child.nextSibling) visitNode(child, out, ctx, visible, ariaHidden, skipText);
      }
    }
    for (const id of (el.getAttribute("aria-owns") || "").split(/\s+/).filter(Boolean)) {
      const owned = el.ownerDocument.getElementById(id);
      if (owned && owned !== el) visitNode(owned, out, ctx, visible, ariaHidden, skipText);
    }
    if (visible && !skipText) out.push(pseudoText(el, "::after"));
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
            ctx.offscreen += el.querySelectorAll(INTERACTIVE_SELECTOR).length + (el.matches(INTERACTIVE_SELECTOR) ? 1 : 0);
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
    const name = flattens && !interactive && !scrollable ? "" : nodeName(el, role, !visible);
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
    if ((role === "link" || role === "button") && visible && !ctx.showHidden && !hasVisibleBox(el)) return;
    const node = { role };
    if (name) node.name = name;
    if (interactive || scrollable) node.act = 1;
    if (interactive || scrollable || role === "iframe" || (name && SCOPE_ROLES.has(role))) node.ref = refFor(el);
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
    const value = valueOf(el, role, tag);
    if (value !== null) node.value = value;
    if (role === "link") {
      const url = displayUrl(el);
      if (url) node.url = url;
      const offsite = offsiteSummary(el);
      if (offsite) node.offsite = offsite;
    }
    const placeholder = el.getAttribute("placeholder");
    if (placeholder && normalize(placeholder) !== name && (tag === "input" || tag === "textarea")) node.placeholder = normalize(placeholder);
    if (tag === "select") {
      const options = [...el.options].map((o) => (o.selected ? { name: normalize(o.label || o.textContent), selected: true } : { name: normalize(o.label || o.textContent) }));
      // A list box shows its options; a drop-down shows them on request.
      if (el.multiple || el.size > 1) node.children = options.map((o) => Object.assign({ role: "option" }, o));
      else node.options = options;
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

  // opts: { root: handle | null, showHidden, base } -> { nodes, max }
  const now = () => (global.performance && global.performance.now ? global.performance.now() : Date.now());
  function snapshot(opts) {
    const started = now();
    opts = opts || {};
    raiseRefBase(opts.base);
    pruneRefs();
    const root = opts.root ? element(opts.root) : document.body || document.documentElement;
    if (!root || !root.isConnected) throw agentError("stale", "The snapshot root was removed from the page");
    const ctx = {
      showHidden: !!opts.showHidden,
      focus: deepActiveElement(document),
      visited: new Set(),
      depth: 0,
      clips: EMPTY_CLIPS,
      positioned: -1,
      transformed: -1,
      viewport: opts.viewport ? { left: 0, top: 0, right: global.innerWidth, bottom: global.innerHeight } : null,
      offscreen: 0,
    };
    const out = [];
    visitElement(root, out, ctx, false, false);
    const nodes = normalizeChildren(out);
    // `ms` is the traversal time in this frame, for perf measurements.
    return { nodes, max: refCounter, offscreen: ctx.offscreen, ms: now() - started };
  }

  // Table sizes, for leak checks (tests/browser-parity/perf).
  function stats() {
    return { refs: refRegistry.size, handles: handles.size };
  }

  function refState(ref, base) {
    raiseRefBase(base);
    return { live: !!refElement(ref), max: refCounter };
  }

  function refForHandle(id, base) {
    raiseRefBase(base);
    return { ref: refFor(element(id)), max: refCounter };
  }

  // The topmost element at a viewport point, raised to its nearest control,
  // scrollable region or iframe so the ref is something an agent can act on.
  function elementAt(x, y, base) {
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
    };
  }

  if (injected) {
    injected._engines.set("aria-ref", {
      queryAll(root, selector) {
        const el = refElement(String(selector).trim());
        return el ? [el] : [];
      },
    });
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

  function queryAll(selector, scopeHandle) {
    const inj = requireInjected();
    const root = scopeHandle ? element(scopeHandle) : document;
    const parsed = inj.parseSelector(selector);
    return inj.querySelectorAll(parsed, root).map(handleFor);
  }

  function describe(id) {
    return requireInjected().previewNode(element(id));
  }

  function strictError(selector, ids) {
    return requireInjected().strictModeViolationError(requireInjected().parseSelector(selector), ids.map(element)).message;
  }

  async function checkStates(id, states) {
    const result = await requireInjected().checkElementStates(element(id), states);
    return result === undefined ? "done" : result;
  }

  function elementState(id, state) {
    return requireInjected().elementState(element(id), state);
  }

  function isInViewport(rect) {
    return rect.top >= 0 && rect.left >= 0 && rect.bottom <= global.innerHeight && rect.right <= global.innerWidth;
  }

  function scrollIntoViewIfNeeded(id) {
    const el = element(id);
    if (!el.isConnected) return "error:notconnected";
    const rect = el.getBoundingClientRect();
    if (isInViewport(rect)) return "done";
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
    if (before !== undefined && active !== (before ? handles.get(before) : doc.body) && active !== doc.body) return false;
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
      default:
        throw agentError("invalid", `Unknown read ${what}`);
    }
  }

  function iframeHandles() {
    const out = [];
    const walk = (root) => {
      for (const el of root.querySelectorAll("*")) {
        const tag = tagOf(el);
        if (tag === "iframe" || tag === "frame") out.push(handleFor(el));
        if (el.shadowRoot) walk(el.shadowRoot);
      }
    };
    walk(document);
    return out;
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

  // ---------------------------------------------------------------------------
  // Annotated screenshots: boxes and labels in a closed shadow root that is
  // removed right after capture. `refs` are [localRef, label] pairs.

  let overlay = null;
  function annotate(refs) {
    clearAnnotations();
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
    iframeHandles,
    contentBox,
    annotate,
    clearAnnotations,
    injected,
  };
  Object.defineProperty(global, KEY, { value: agent, enumerable: false, configurable: true, writable: false });
  // The Swift driver resolves handles for input.setFiles through this name.
  Object.defineProperty(global, "__cmuxPageAgent", {
    value: { resolveHandle: (id) => handles.get(id) || null },
    enumerable: false,
    configurable: true,
    writable: false,
  });
})(globalThis, typeof __cmuxInjectedScriptFactory !== "undefined" ? __cmuxInjectedScriptFactory : null);
