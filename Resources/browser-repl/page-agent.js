// cmux browser REPL page agent.
//
// Installed by the driver into every frame's isolated "agent" world. It owns
// the Aside snapshot (docs/browser-repl/aside-snapshot-spec.md), the per
// document ref table, element handles, and the DOM helpers the runtime's
// actionability checks need. Locator semantics come from Playwright's
// InjectedScript so they match Playwright exactly.
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

  // ---------------------------------------------------------------------------
  // Roles

  const ARIA_ROLES = new Set(("alert alertdialog application article banner blockquote button caption cell checkbox code " +
    "columnheader combobox complementary contentinfo definition deletion dialog directory document emphasis feed figure " +
    "form generic grid gridcell group heading img insertion link list listbox listitem log main mark marquee math meter " +
    "menu menubar menuitem menuitemcheckbox menuitemradio navigation none note option paragraph presentation progressbar " +
    "radio radiogroup region row rowgroup rowheader scrollbar search searchbox separator slider spinbutton status strong " +
    "subscript superscript switch tab table tablist tabpanel term textbox time timer toolbar tooltip tree treegrid treeitem").split(" "));
  const TAG_ROLES = {
    a: "link", button: "button", iframe: "iframe", select: "combobox", textarea: "textbox",
    h1: "heading", h2: "heading", h3: "heading", h4: "heading", h5: "heading", h6: "heading",
    canvas: "canvas", svg: "image", img: "image", nav: "navigation", main: "main", header: "banner",
    footer: "contentinfo", section: "region", article: "article", aside: "complementary", form: "form",
    table: "table", ul: "list", ol: "list", li: "listitem", p: "paragraph", label: "label",
  };
  const PROHIBITED_NAME_ROLES = new Set(["caption", "code", "definition", "deletion", "emphasis", "generic", "insertion",
    "mark", "paragraph", "presentation", "strong", "subscript", "superscript", "term", "time"]);
  const NAME_FROM_CONTENT_ROLES = new Set(["button", "link", "heading", "cell", "columnheader", "rowheader", "tooltip",
    "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "treeitem", "option", "listitem", "row", "term"]);
  const REF_ROLES = new Set(["button", "link", "textbox", "checkbox", "radio", "combobox", "listbox", "menuitem",
    "menuitemcheckbox", "menuitemradio", "option", "searchbox", "slider", "spinbutton", "switch", "tab", "treeitem"]);
  const NAMED_REF_ROLES = new Set(["cell", "gridcell", "columnheader", "rowheader", "listitem", "article", "region",
    "main", "navigation"]);
  const DISABLED_ROLES = new Set(["application", "button", "composite", "gridcell", "group", "input", "link", "menuitem",
    "scrollbar", "separator", "tab", "checkbox", "columnheader", "combobox", "grid", "listbox", "menu", "menubar",
    "menuitemcheckbox", "menuitemradio", "option", "radio", "radiogroup", "row", "rowheader", "searchbox", "select",
    "slider", "spinbutton", "switch", "tablist", "textbox", "toolbar", "tree", "treegrid", "treeitem"]);
  const LANDMARK_TAGS = new Set(["h1", "h2", "h3", "h4", "h5", "h6", "nav", "main", "header", "footer", "section", "article", "aside"]);
  const INTERACTIVE_TAGS = new Set(["a", "button", "input", "select", "textarea", "details", "summary"]);
  const SKIP_TAGS = new Set(["script", "style", "meta", "link", "title", "noscript"]);
  const LEAF_MERGE_ROLES = new Set(["generic", "heading", "paragraph", "label"]);

  const tagOf = (el) => (el.localName || el.tagName || "").toLowerCase();
  const styleOf = (el, pseudo) => {
    try {
      return global.getComputedStyle(el, pseudo || null);
    } catch {
      return null;
    }
  };

  function explicitRole(el) {
    const attr = el.getAttribute && el.getAttribute("role");
    if (!attr) return null;
    for (const token of attr.split(" ")) {
      const role = token.toLowerCase();
      if (!ARIA_ROLES.has(role)) continue;
      if (role === "presentation" || role === "none") return null;
      return role;
    }
    return null;
  }

  function isContentEditableHost(el) {
    const ce = el.contentEditable;
    return ce === "true" || ce === "plaintext-only";
  }

  function implicitRole(el) {
    if (isContentEditableHost(el)) return "textbox";
    const tag = tagOf(el);
    if (tag === "input") {
      const type = (el.type || "").toLowerCase();
      if (type === "submit" || type === "button" || type === "file") return "button";
      if (type === "checkbox") return "checkbox";
      if (type === "radio") return "radio";
      return "textbox";
    }
    return TAG_ROLES[tag] || "generic";
  }

  function roleOf(el) {
    return explicitRole(el) || implicitRole(el);
  }

  // ---------------------------------------------------------------------------
  // Accessible name (section 5)

  const collapse = (s) => String(s).replace(/\s+/g, " ");
  const normalizeName = (s) => collapse(s || "").trim().slice(0, 100);

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

  function accessibleName(el) {
    const role = roleOf(el);
    if (PROHIBITED_NAME_ROLES.has(role)) return "";
    return collapse(computeName(el, { inLabelledBy: false, inLabel: false, depth: 0, visited: new Set() })).trim().slice(0, 300);
  }

  function computeName(el, ctx) {
    if (ctx.depth >= 10 || ctx.visited.has(el)) return "";
    const visited = new Set(ctx.visited);
    visited.add(el);
    const next = { inLabelledBy: ctx.inLabelledBy, inLabel: ctx.inLabel, depth: ctx.depth + 1, visited };
    const labelContext = ctx.inLabelledBy || ctx.inLabel;
    if (!labelContext) {
      if (el.getAttribute("aria-hidden") === "true") return "";
      const cs = styleOf(el);
      if (cs && (cs.display === "none" || cs.visibility === "hidden")) return "";
    }
    if (!ctx.inLabelledBy) {
      const ids = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
      if (ids.length) {
        const doc = el.ownerDocument;
        const parts = [];
        for (const id of ids) {
          const target = doc.getElementById(id);
          if (target) parts.push(computeName(target, { ...next, inLabelledBy: true }));
        }
        const text = collapse(parts.join(" ")).trim();
        if (text) return text;
      }
    }
    const ariaLabel = (el.getAttribute("aria-label") || "").trim();
    if (ariaLabel) return ariaLabel;
    const tag = tagOf(el);
    if (!labelContext && ["input", "textarea", "select", "meter", "progress", "output"].includes(tag)) {
      const labels = [];
      if (el.id) {
        for (const label of el.ownerDocument.querySelectorAll("label[for]")) {
          if (label.getAttribute("for") === el.id) labels.push(label);
        }
      }
      const enclosing = el.closest && el.closest("label");
      if (enclosing && !labels.includes(enclosing)) labels.push(enclosing);
      if (labels.length) {
        const text = collapse(labels.map((l) => computeName(l, { ...next, inLabel: true })).join(" ")).trim();
        if (text) return text;
      }
    }
    if (tag === "img" || tag === "area" || (tag === "input" && (el.type || "").toLowerCase() === "image")) {
      const alt = el.getAttribute("alt");
      if (alt !== null) return alt.trim();
    }
    const childFor = { fieldset: "legend", figure: "figcaption", table: "caption" }[tag];
    if (childFor) {
      const child = [...el.children].find((c) => tagOf(c) === childFor);
      if (child) {
        const text = computeName(child, next);
        if (text) return text;
      }
    }
    if (tag === "select") {
      const option = el.options && el.options[el.selectedIndex];
      const text = option ? (option.textContent || "").trim() : "";
      if (text) return text;
    }
    const role = roleOf(el);
    if (NAME_FROM_CONTENT_ROLES.has(role) || labelContext) {
      let text = pseudoText(el, "::before");
      for (const child of el.childNodes) {
        if (child.nodeType === 3) text += child.nodeValue;
        else if (child.nodeType === 1) text += computeName(child, next);
      }
      text += pseudoText(el, "::after");
      text = collapse(text).trim();
      if (text) return text;
    }
    if (tag === "input") {
      const type = (el.type || "").toLowerCase();
      if (type === "submit" || type === "button") {
        const value = (el.value || "").trim();
        if (value) return value;
      }
    }
    const placeholder = (el.getAttribute("placeholder") || "").trim();
    if (placeholder) return placeholder;
    return (el.getAttribute("title") || "").trim();
  }

  // ---------------------------------------------------------------------------
  // Visibility and classification (section 6)

  function parentCrossingShadow(el) {
    if (el.parentElement) return el.parentElement;
    const root = el.parentNode;
    if (root && root.nodeType === 11 && root.host) return root.host;
    return null;
  }

  function computeVisible(el) {
    if (el.getAttribute("aria-hidden") === "true") return false;
    const tag = tagOf(el);
    // WebKit gives options in a closed <select> a style and no layout, so the
    // Chromium checks below would call them visible. Aside never walks them.
    if (tag === "option" || tag === "optgroup") {
      const select = el.closest("select");
      if (select && !select.multiple && !(select.size > 1)) return false;
    }
    const own = styleOf(el);
    let hasContents = false;
    const html = el.ownerDocument.documentElement;
    for (let cur = el; cur && cur !== html; cur = parentCrossingShadow(cur)) {
      const cs = styleOf(cur);
      if (!cs) continue;
      if (cs.display === "contents") {
        hasContents = true;
        continue;
      }
      if (cs.display === "none") return false;
      const clips = (v) => v === "hidden" || v === "clip";
      if ((clips(cs.overflow) || clips(cs.overflowX) || clips(cs.overflowY)) && (cur.offsetWidth === 0 || cur.offsetHeight === 0)) return false;
      if (tagOf(cur) === "iframe" && (cur.offsetWidth === 0 || cur.offsetHeight === 0)) return false;
      if (cs.visibility === "hidden" && !(own && own.visibility === "visible")) return false;
      if (Number(cs.opacity) === 0) return false;
    }
    if (typeof el.checkVisibility === "function" && !hasContents) {
      if (!el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
    }
    if (el instanceof global.HTMLElement) {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0 && (r.right <= 0 || r.bottom <= 0)) {
        if (own && own.overflowX !== "visible" && own.overflowY !== "visible") return false;
      }
    }
    return true;
  }

  function isInteractive(el) {
    const tag = tagOf(el);
    if (INTERACTIVE_TAGS.has(tag)) return true;
    if (el.hasAttribute("onclick")) return true;
    const tabindex = el.getAttribute("tabindex");
    if (tabindex !== null && tabindex !== "-1") return true;
    const role = explicitRole(el);
    if (role === "button" || role === "link") return true;
    if (el.getAttribute("contenteditable") === "true") return true;
    const cs = styleOf(el);
    if (cs && cs.cursor === "pointer") {
      const parent = parentCrossingShadow(el);
      const parentStyle = parent && styleOf(parent);
      if (parentStyle && parentStyle.cursor === "pointer") return false;
      return true;
    }
    return false;
  }

  function isScrollable(el) {
    const tag = tagOf(el);
    if (tag === "html" || tag === "body") return false;
    const cs = styleOf(el);
    if (!cs) return false;
    const scrolls = (v) => v === "auto" || v === "scroll" || v === "overlay";
    if (!scrolls(cs.overflowX) && !scrolls(cs.overflowY)) return false;
    return el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1;
  }

  function isLandmark(el) {
    return LANDMARK_TAGS.has(tagOf(el)) || explicitRole(el) !== null;
  }

  // ---------------------------------------------------------------------------
  // Snapshot state. The counter and per-element cache live as long as this
  // document's agent world.

  const snap = { counter: 0, cache: new WeakMap(), registry: new Map(), meta: new Map() };

  function createContext(opts) {
    const vis = new Map();
    const ctx = {
      interactive: !!opts.interactive,
      showHidden: !!opts.showHidden,
      maxDepth: typeof opts.maxDepth === "number" ? opts.maxDepth : 50,
      prefix: opts.refPrefix || "",
      ref: opts.ref || null,
      visited: new Set(),
      refs: {},
      signatures: new Map(),
      iframes: [],
      isVisible(el) {
        if (!vis.has(el)) vis.set(el, computeVisible(el));
        return vis.get(el);
      },
    };
    return ctx;
  }

  function shouldTraverse(el, ctx) {
    if (SKIP_TAGS.has(tagOf(el))) return false;
    if (el.getAttribute("aria-hidden") === "true" && el.childElementCount === 0) return false;
    if (!ctx.showHidden && !ctx.isVisible(el)) {
      const type = tagOf(el) === "input" ? (el.type || "").toLowerCase() : "";
      return type === "radio" || type === "checkbox";
    }
    return true;
  }

  function shouldInclude(el, ctx) {
    const role = roleOf(el);
    if (ctx.interactive) return role === "canvas" || isInteractive(el) || isScrollable(el) || isLandmark(el);
    if (isInteractive(el) || isScrollable(el) || isLandmark(el)) return true;
    if (accessibleName(el)) return true;
    return role !== "generic" && role !== "image";
  }

  function assignRef(el, role, name, ctx) {
    const cached = snap.cache.get(el);
    let ref;
    if (cached && cached.role === role && cached.name === name && cached.prefix === ctx.prefix) {
      ref = cached.ref;
    } else {
      ref = `${ctx.prefix}e${++snap.counter}`;
      snap.cache.set(el, { role, name, ref, prefix: ctx.prefix });
    }
    snap.registry.set(ref, el);
    const fullName = accessibleName(el).slice(0, 100);
    const signature = `${role}::${fullName}`;
    const nth = ctx.signatures.get(signature) || 0;
    ctx.signatures.set(signature, nth + 1);
    const meta = { role, name: fullName, tagName: el.tagName.toUpperCase() };
    if (typeof el.type === "string" && el.type) meta.inputType = el.type;
    const ariaLabel = el.getAttribute("aria-label");
    if (ariaLabel) meta.ariaLabel = ariaLabel;
    const placeholder = el.getAttribute("placeholder");
    if (placeholder) meta.placeholder = placeholder;
    meta.nthAmongSameSignature = nth;
    ctx.refs[ref] = meta;
    snap.meta.set(ref, meta);
    if (role === "iframe") ctx.iframes.push({ ref, handle: handleFor(el) });
    return ref;
  }

  function valueChild(el) {
    if (isContentEditableHost(el)) return el.innerText;
    const tag = tagOf(el);
    if (tag === "input") {
      const type = (el.type || "").toLowerCase();
      if (type === "checkbox" || type === "radio" || type === "file") return null;
      if (type === "password") return el.value ? "[redacted]" : "";
      return el.value;
    }
    if (tag === "textarea") return el.value;
    return null;
  }

  function isNativeDisabled(el) {
    const tag = tagOf(el);
    if (!["button", "input", "select", "textarea", "option", "optgroup"].includes(tag)) return false;
    try {
      return el.matches(":disabled");
    } catch {
      return false;
    }
  }

  function ariaDisabled(el) {
    for (let cur = el; cur; cur = parentCrossingShadow(cur)) {
      if (cur.getAttribute && cur.getAttribute("aria-disabled") === "true") return true;
    }
    return false;
  }

  function toNode(el, ctx) {
    const role = roleOf(el);
    const name = normalizeName(accessibleName(el));
    const visible = ctx.isVisible(el);
    const scrollable = isScrollable(el);
    const needsRef = role === "iframe" || role === "canvas" || scrollable || isInteractive(el) || REF_ROLES.has(role) ||
      (NAMED_REF_ROLES.has(role) && !!name);
    if (role === "generic" && !needsRef && visible) return null;
    const node = { role, name, hidden: !visible, scrollable, children: [] };
    if (needsRef) node.ref = assignRef(el, role, name, ctx);
    const tag = tagOf(el);
    if (["heading", "listitem", "row", "treeitem"].includes(role)) {
      if (role === "heading" && /^h[1-6]$/.test(tag)) node.level = Number(tag[1]);
      else {
        const level = Number(el.getAttribute("aria-level"));
        if (Number.isInteger(level) && level >= 1) node.level = level;
      }
    }
    const inputType = tag === "input" ? (el.type || "").toLowerCase() : "";
    if (inputType === "checkbox" || inputType === "radio") node.checked = !!el.checked;
    else if (["checkbox", "radio", "menuitemcheckbox", "menuitemradio", "switch"].includes(role)) {
      node.checked = (el.getAttribute("aria-checked") || "").toLowerCase() === "true";
    }
    if (tag === "option") node.selected = !!el.selected;
    else if (["gridcell", "option", "row", "tab", "rowheader", "columnheader", "treeitem"].includes(role)) {
      node.selected = el.getAttribute("aria-selected") === "true";
    }
    if (DISABLED_ROLES.has(role)) node.disabled = isNativeDisabled(el) || ariaDisabled(el);
    node.focused = el.ownerDocument.activeElement === el;
    const placeholder = el.getAttribute("placeholder");
    if (placeholder) node.placeholder = placeholder;
    if (role === "canvas") {
      const r = el.getBoundingClientRect();
      node.size = `${Math.round(r.width)}x${Math.round(r.height)}`;
    }
    if (tag === "select") node.select = el;
    const value = valueChild(el);
    if (value !== null && value !== undefined) node.children.push(value);
    return node;
  }

  function ariaOwned(el) {
    const ids = (el.getAttribute("aria-owns") || "").split(/\s+/).filter(Boolean);
    const out = [];
    for (const id of ids) {
      const target = el.ownerDocument.getElementById(id);
      if (target && target !== el && !out.includes(target)) out.push(target);
    }
    return out;
  }

  function traverse(el, depth, parent, ctx) {
    if (depth > ctx.maxDepth || ctx.visited.has(el)) return;
    ctx.visited.add(el);
    const traversable = shouldTraverse(el, ctx);
    const isRoot = !ctx.ref && el === el.ownerDocument.body;
    const include = isRoot || (traversable && (shouldInclude(el, ctx) || (ctx.showHidden && !ctx.isVisible(el))));
    if (!traversable && !isRoot) return;
    let target = parent;
    let node = null;
    if (include) {
      node = toNode(el, ctx);
      if (node) {
        parent.children.push(node);
        target = node;
      }
    }
    if (!include && ctx.interactive && el.childNodes.length === 0) {
      const n = normalizeName(accessibleName(el));
      if (n && !target.fragment) target.children.push(n);
    }
    if (depth < ctx.maxDepth) {
      const before = pseudoText(el, "::before");
      if (before) target.children.push(before);
      const next = include && node ? depth + 1 : depth;
      const kids = [...el.childNodes];
      if (el.shadowRoot) kids.push(...el.shadowRoot.childNodes);
      for (const child of kids) {
        if (child.nodeType === 3) {
          if (child.nodeValue && target.role !== "textbox") target.children.push(child.nodeValue);
        } else if (child.nodeType === 1) {
          traverse(child, next, target, ctx);
        }
      }
      for (const owned of ariaOwned(el)) traverse(owned, next, target, ctx);
      const after = pseudoText(el, "::after");
      if (after) target.children.push(after);
    }
  }

  // ---------------------------------------------------------------------------
  // Normalization passes (section 7)

  function mergeStrings(parts) {
    let acc = "";
    for (const part of parts) {
      if (!part) continue;
      if (/[\p{L}\p{N}]$/u.test(acc.trimEnd()) && /^[\p{L}\p{N}]/u.test(part.trimStart())) acc += " ";
      acc += part;
    }
    return acc.trim();
  }

  function isBareParagraph(node) {
    return typeof node !== "string" && node.role === "paragraph" && !node.name && node.level === undefined && !node.hidden &&
      !node.scrollable && !node.checked && !node.selected && !node.focused && !node.disabled && !node.ref &&
      !node.placeholder && !node.size;
  }

  function passStrings(node) {
    for (const child of node.children) if (typeof child !== "string") passStrings(child);
    const out = [];
    let run = [];
    const flush = () => {
      if (!run.length) return;
      const merged = mergeStrings(run);
      if (merged) out.push(merged);
      run = [];
    };
    for (const child of node.children) {
      if (typeof child === "string") run.push(child);
      else if (isBareParagraph(child) && child.children.every((c) => typeof c === "string")) run.push(mergeStrings(child.children));
      else {
        flush();
        out.push(child);
      }
    }
    flush();
    node.children = out;
    if (node.children.length === 1 && typeof node.children[0] === "string" && node.children[0] === node.name) node.children = [];
  }

  function hasRef(node) {
    return node.children.some((c) => typeof c !== "string" && (c.ref || hasRef(c)));
  }

  function passWrappers(node) {
    if (typeof node === "string") return [node];
    node.children = node.children.flatMap(passWrappers);
    const kids = node.children;
    if (node.hidden && !node.ref && !hasRef(node)) return [];
    if (isBareParagraph(node) && kids.length === 1 && typeof kids[0] !== "string" && kids[0].role === "paragraph") return [kids[0]];
    if (node.role === "generic" && !node.hidden && !node.name && kids.length <= 1 && kids.every((c) => typeof c !== "string" && c.ref)) {
      return kids;
    }
    return [node];
  }

  function passLeafText(node) {
    for (const child of node.children) if (typeof child !== "string") passLeafText(child);
    const kids = node.children;
    if (node.hidden || !node.ref || kids.length < 1 || kids.length > 3) return;
    const eligible = kids.every((c) => typeof c === "string"
      ? c.trim() !== ""
      : !c.hidden && LEAF_MERGE_ROLES.has(c.role) && !!c.name && c.children.length === 0);
    if (!eligible) return;
    const merged = normalizeName(kids.map((c) => (typeof c === "string" ? c : c.name)).join(" "));
    if (!node.name) {
      node.name = merged;
      node.children = [];
    } else if (node.name.replace(/\s+/g, "") === merged.replace(/\s+/g, "")) {
      node.children = [];
    }
  }

  // ---------------------------------------------------------------------------
  // Rendering (section 8)

  const esc = (s) => String(s).replace(/"/g, '\\"').replace(/\n/g, "\\n");

  function nodeHead(node) {
    let head = node.role;
    if (node.name) head += ` "${esc(node.name)}"`;
    if (node.ref) head += ` [ref=${node.ref}]`;
    if (node.level !== undefined) head += ` [level=${node.level}]`;
    if (node.hidden) head += " [hidden]";
    if (node.scrollable) head += " [scrollable]";
    if (node.checked) head += " [checked]";
    if (node.disabled) head += " [disabled]";
    if (node.focused) head += " [focused]";
    if (node.selected) head += " [selected]";
    if (node.placeholder) head += ` [placeholder="${esc(node.placeholder)}"]`;
    if (node.size) head += ` [size=${node.size}]`;
    return head;
  }

  function render(node, depth, lines) {
    const indent = "  ".repeat(depth);
    const kids = node.children;
    if (kids.length === 1 && typeof kids[0] === "string" && !node.select) {
      const text = kids[0].trim();
      lines.push(`${indent}- ${nodeHead(node)}${text ? `: "${esc(text)}"` : ""}`);
      return;
    }
    lines.push(`${indent}- ${nodeHead(node)}${kids.length || node.select ? ":" : ""}`);
    if (node.select) {
      for (const option of node.select.options) {
        const raw = (option.textContent || "").trim();
        const text = collapse(raw).slice(0, 100);
        let line = `${indent}  - option`;
        if (text) line += ` "${esc(text)}"`;
        if (option.selected) line += " (selected)";
        if (option.value && option.value !== raw) line += ` value="${esc(option.value)}"`;
        lines.push(line);
      }
    }
    for (const child of kids) {
      if (typeof child === "string") {
        const text = child.trim();
        if (text) lines.push(`${indent}  - text: "${esc(text)}"`);
      } else {
        render(child, depth + 1, lines);
      }
    }
  }

  function collectRefs(node, seen, dupes) {
    for (const child of node.children) {
      if (typeof child === "string") continue;
      if (child.ref) {
        if (seen.has(child.ref)) dupes.add(child.ref);
        seen.add(child.ref);
      }
      collectRefs(child, seen, dupes);
    }
  }

  function findByImplicitRole(selector) {
    const m = /^\[role=(?:"([^"]*)"|'([^']*)')\]$/.exec(selector.trim());
    if (!m) return null;
    const want = m[1] !== undefined ? m[1] : m[2];
    for (const el of document.querySelectorAll("*")) if (roleOf(el) === want) return el;
    return null;
  }

  function snapshot(opts) {
    opts = opts || {};
    const ctx = createContext(opts);
    let root;
    // deref() falls back to the refs of the latest snapshot only.
    const previousMeta = snap.meta;
    snap.meta = new Map();
    if (ctx.ref) {
      root = snap.registry.get(ctx.ref);
      if (!root || !root.isConnected) {
        snap.meta = previousMeta;
        return { error: `Element with ref '${ctx.ref}' not found. It may have been removed from the page. Take a snapshot without 'ref' to get the current page state.` };
      }
      snap.registry.clear();
      snap.registry.set(ctx.ref, root);
    } else {
      snap.registry.clear();
      if (opts.selector) {
        root = document.querySelector(opts.selector) || findByImplicitRole(opts.selector);
        if (!root) return { text: "", refs: {}, iframes: [] };
      } else {
        root = document.body;
      }
    }
    const fragment = { role: "fragment", fragment: true, children: [] };
    if (root) traverse(root, 0, fragment, ctx);
    passStrings(fragment);
    fragment.children = fragment.children.flatMap(passWrappers);
    passLeafText(fragment);
    const dupes = new Set();
    collectRefs(fragment, new Set(), dupes);
    if (dupes.size) {
      return { error: `Snapshot produced duplicate refs: ${[...dupes].sort().join(", ")}. Take a new snapshot and retry.` };
    }
    const lines = [];
    for (const child of fragment.children) {
      if (typeof child === "string") {
        const text = child.trim();
        if (text) lines.push(`- text: "${esc(text)}"`);
      } else {
        render(child, 0, lines);
      }
    }
    const text = lines.join("\n");
    if (typeof opts.maxChars === "number" && text.length > opts.maxChars) {
      const hint = ctx.ref
        ? "The specified element has too much content. Try a smaller maxDepth or focus on a more specific child element."
        : "Try an even smaller maxDepth, or 'ref' to focus on a specific element from the page.";
      return { error: `Output exceeds ${opts.maxChars} character limit (${text.length} characters). ${hint}` };
    }
    return { text, refs: ctx.refs, iframes: ctx.iframes };
  }

  // Rebinds a ref after a re-render when exactly one element (or the nth) has
  // the ref's role and name (section 10).
  function deref(ref) {
    const el = snap.registry.get(ref);
    if (el && el.isConnected) return el;
    const meta = snap.meta.get(ref);
    if (!meta || !document.body) return null;
    const candidates = [];
    let seen = 0;
    for (const cur of document.body.querySelectorAll("*")) {
      if (++seen > 5000) break;
      if (roleOf(cur) === meta.role && accessibleName(cur).slice(0, 300) === meta.name) candidates.push(cur);
    }
    if (candidates.length === 1) return candidates[0];
    return candidates[meta.nthAmongSameSignature] || null;
  }

  if (injected) {
    injected._engines.set("aria-ref", {
      queryAll(root, selector) {
        const el = deref(String(selector).trim().replace(/^\[ref=(.*)\]$/, "$1"));
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
  // removed right after capture.

  let overlay = null;
  function annotate(refs) {
    clearAnnotations();
    const host = document.createElement("cmux-annotations");
    host.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483647;display:block";
    const root = host.attachShadow({ mode: "closed" });
    for (const ref of refs) {
      const el = snap.registry.get(ref);
      if (!el || !el.isConnected) continue;
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      if (r.bottom < 0 || r.right < 0 || r.top > global.innerHeight || r.left > global.innerWidth) continue;
      const box = document.createElement("div");
      box.style.cssText = `position:fixed;left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px;` +
        "border:2px solid #e5007a;box-sizing:border-box";
      const label = document.createElement("div");
      label.textContent = ref;
      label.style.cssText = `position:fixed;left:${r.left}px;top:${Math.max(0, r.top - 14)}px;background:#e5007a;` +
        "color:#fff;font:bold 10px/14px monospace;padding:0 3px";
      root.append(box, label);
    }
    (document.body || document.documentElement).appendChild(host);
    overlay = host;
    return "done";
  }
  function clearAnnotations() {
    if (overlay) overlay.remove();
    overlay = null;
    return "done";
  }

  // ---------------------------------------------------------------------------
  // ChatGPT accessibility tree (docs/browser-repl/chatgpt-ax-spec.md, 1.1).
  //
  // ChatGPT renders Chromium's CDP accessibility tree. WebKit exposes no such
  // tree to page script, so this builds the same shape from DOM and ARIA:
  // Chromium role strings, names and their sources, the properties the
  // renderer reads, and Chromium's structural quirks (list markers, redundant
  // checkbox labels, select popups, disclosure triangles). Each node carries a
  // stable `key` (an element handle) so revisions can keep element IDs.

  const CREDENTIAL = /user[-_ ]?name|e[-_ ]?mail|one[-_ ]?time[-_ ]?code|password|passcode|passwd|\botp\b|\b(?:2fa|mfa)\b|phone|mobile|\btel\b/i;
  const AX_SKIP = new Set(["script", "style", "template", "head", "noscript", "title", "meta", "link", "base"]);
  const INPUT_ROLES = {
    "": "textbox", text: "textbox", email: "textbox", tel: "textbox", url: "textbox", password: "textbox",
    search: "searchbox", number: "spinbutton", range: "slider", checkbox: "checkbox", radio: "radio",
    submit: "button", button: "button", reset: "button", image: "button", file: "button",
    color: "ColorWell", date: "Date", time: "InputTime", "datetime-local": "DateTime", month: "Date", week: "Date",
  };
  const CHROME_TAG_ROLES = {
    button: "button", textarea: "textbox", h1: "heading", h2: "heading", h3: "heading", h4: "heading",
    h5: "heading", h6: "heading", nav: "navigation", main: "main", article: "article", aside: "complementary",
    form: "form", ul: "list", ol: "list", menu: "list", li: "listitem", dl: "DescriptionList", dt: "term", dd: "definition",
    p: "paragraph", label: "LabelText", canvas: "Canvas", table: "table", caption: "caption", thead: "rowgroup",
    tfoot: "rowgroup", tr: "row", td: "cell", fieldset: "group", legend: "Legend", details: "group",
    summary: "DisclosureTriangle", dialog: "dialog", strong: "strong", em: "emphasis", code: "code", pre: "Pre",
    blockquote: "blockquote", figure: "figure", figcaption: "Figcaption", hr: "separator", progress: "progressbar",
    meter: "meter", output: "status", iframe: "Iframe", frame: "Iframe", video: "Video", audio: "Audio",
    mark: "mark", ins: "insertion", del: "deletion", time: "time", abbr: "Abbr", sub: "subscript", sup: "superscript",
    search: "search", br: "LineBreak", math: "math",
  };
  const NAME_FROM_CONTENTS = new Set(["button", "cell", "checkbox", "columnheader", "gridcell", "heading", "link",
    "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "rowheader", "switch", "tab", "tooltip",
    "treeitem", "DisclosureTriangle", "caption", "Legend", "LabelText", "term", "Figcaption"]);

  function chromeRole(el) {
    const tag = tagOf(el);
    const explicit = explicitRole(el);
    if (explicit) return explicit;
    if (tag === "a" || tag === "area") return el.hasAttribute("href") ? "link" : "generic";
    if (tag === "input") {
      const type = (el.getAttribute("type") || "").toLowerCase();
      if (type === "hidden") return null;
      return INPUT_ROLES[type] || "textbox";
    }
    if (tag === "select") return el.multiple || el.size > 1 ? "listbox" : "combobox";
    if (tag === "img") return el.getAttribute("alt") === "" ? null : "image";
    if (tag === "svg") return "image";
    if (tag === "section") return accessibleNameSource(el, "region").name ? "region" : "Section";
    if (tag === "header" || tag === "footer") {
      const scoped = el.parentElement && el.parentElement.closest("article, aside, main, nav, section");
      if (scoped) return tag === "header" ? "SectionHeader" : "SectionFooter";
      return tag === "header" ? "banner" : "contentinfo";
    }
    if (tag === "th") return el.getAttribute("scope") === "row" ? "rowheader" : "columnheader";
    if (isContentEditableHost(el) && !(el.parentElement && el.parentElement.isContentEditable)) return "generic";
    if (CHROME_TAG_ROLES[tag]) return CHROME_TAG_ROLES[tag];
    if (el.getAttribute("draggable") === "true") return "group";
    return "generic";
  }

  function idrefText(el, attr) {
    const ids = (el.getAttribute(attr) || "").split(/\s+/).filter(Boolean);
    const parts = [];
    for (const id of ids) {
      const target = el.ownerDocument.getElementById(id);
      if (target) parts.push(injected ? injected.utils.getElementAccessibleName(target, true) || collapse(target.textContent || "").trim() : collapse(target.textContent || "").trim());
    }
    return collapse(parts.join(" ")).trim();
  }

  function labelsOf(el) {
    return el.labels ? [...el.labels] : [];
  }

  // Chromium's text for name-from-contents: descendant text in tree order,
  // skipping hidden subtrees and, for tree items, nested groups.
  function contentsText(el, role) {
    let out = "";
    const walk = (node) => {
      for (const child of axChildren(node)) {
        if (child.nodeType === 3) out += child.nodeValue;
        else if (child.nodeType === 1) {
          if (AX_SKIP.has(tagOf(child)) || !axRendered(child)) continue;
          const childRole = chromeRole(child);
          if (role === "treeitem" && (childRole === "group" || childRole === "tree")) continue;
          const own = (child.getAttribute("aria-label") || "").trim();
          if (own) {
            out += " " + own + " ";
            continue;
          }
          if (tagOf(child) === "img") {
            out += child.getAttribute("alt") || "";
            continue;
          }
          const display = (styleOf(child) || {}).display || "";
          const block = display && !display.startsWith("inline") && display !== "contents";
          if (block) out += " ";
          walk(child);
          if (block) out += " ";
        }
      }
    };
    walk(el);
    return collapse(out).trim();
  }

  // Returns { name, source } the way Chromium's CDP reports them.
  function accessibleNameSource(el, role) {
    if (el.hasAttribute("aria-labelledby")) {
      const text = idrefText(el, "aria-labelledby");
      if (text) return { name: text, source: "relatedElement" };
    }
    const ariaLabel = (el.getAttribute("aria-label") || "").trim();
    if (ariaLabel) return { name: ariaLabel, source: "attribute" };
    const tag = tagOf(el);
    if (["input", "select", "textarea", "meter", "progress", "output"].includes(tag)) {
      const type = tag === "input" ? (el.type || "").toLowerCase() : "";
      if (type === "submit" || type === "reset" || type === "button") {
        const v = el.value || (type === "submit" ? "Submit" : type === "reset" ? "Reset" : "");
        if (v) return { name: v, source: "value" };
      }
      const labels = labelsOf(el);
      if (labels.length) {
        const text = collapse(labels.map((l) => {
          let t = "";
          const walk = (n) => {
            for (const c of n.childNodes) {
              if (c === el) continue;
              if (c.nodeType === 3) t += c.nodeValue;
              else if (c.nodeType === 1 && !AX_SKIP.has(tagOf(c)) && axRendered(c)) walk(c);
            }
          };
          walk(l);
          return t;
        }).join(" ")).trim();
        if (text) return { name: text, source: "relatedElement" };
      }
    }
    if (tag === "img" || tag === "area" || (tag === "input" && (el.type || "").toLowerCase() === "image")) {
      const alt = el.getAttribute("alt");
      if (alt) return { name: alt.trim(), source: "attribute" };
    }
    if (tag === "fieldset") {
      const legend = [...el.children].find((c) => tagOf(c) === "legend");
      if (legend) return { name: contentsText(legend, "Legend"), source: "relatedElement" };
    }
    if (tag === "table") {
      const caption = [...el.children].find((c) => tagOf(c) === "caption");
      if (caption) return { name: contentsText(caption, "caption"), source: "relatedElement" };
    }
    if (NAME_FROM_CONTENTS.has(role) && role !== "LabelText" && role !== "Legend" && role !== "caption") {
      const text = contentsText(el, role);
      if (text) return { name: text, source: "contents" };
    }
    const title = (el.getAttribute("title") || "").trim();
    if (title) return { name: title, source: "attribute" };
    const placeholder = (el.getAttribute("placeholder") || "").trim();
    if (placeholder && ["input", "textarea"].includes(tag)) return { name: placeholder, source: "placeholder" };
    return { name: "", source: "relatedElement" };
  }

  function axChildren(node) {
    if (node.nodeType === 1 && node.shadowRoot) return [...node.shadowRoot.childNodes];
    if (node.nodeType === 1 && tagOf(node) === "slot") {
      const assigned = node.assignedNodes();
      return assigned.length ? assigned : [...node.childNodes];
    }
    return [...node.childNodes];
  }

  function axRendered(el) {
    if (el.getAttribute("aria-hidden") === "true") return false;
    if (el.hasAttribute("hidden") && !(styleOf(el) || {}).display) return false;
    const cs = styleOf(el);
    if (cs && cs.display === "none") return false;
    // Closed <details> render only their summary.
    const details = el.parentElement && el.parentElement.closest("details");
    if (details && !details.open) {
      const summary = [...details.children].find((c) => tagOf(c) === "summary");
      if (summary !== el && !(summary && summary.contains(el)) && el !== details) return false;
    }
    return true;
  }

  function textRendered(textNode) {
    try {
      const range = textNode.ownerDocument.createRange();
      range.selectNodeContents(textNode);
      return [...range.getClientRects()].some((r) => r.width > 0 || r.height > 0);
    } catch {
      return true;
    }
  }

  function isBlock(el) {
    const d = (styleOf(el) || {}).display || "";
    return !!d && !d.startsWith("inline") && d !== "contents" && d !== "none";
  }

  // Layout text of a text node: collapsed whitespace, trimmed at block edges.
  function layoutText(textNode) {
    const parent = textNode.parentElement;
    const ws = (parent && styleOf(parent) || {}).whiteSpace || "normal";
    let text = textNode.nodeValue;
    if (ws.startsWith("pre") || ws === "break-spaces") return text;
    text = text.replace(/[ \t\n\r\f]+/g, " ");
    const edge = (sibling, dir) => {
      for (let s = sibling; s; s = s[dir]) {
        if (s.nodeType === 3) {
          if (/\S/.test(s.nodeValue)) return false;
          continue;
        }
        if (s.nodeType === 1) {
          if (!axRendered(s)) continue;
          return isBlock(s) || tagOf(s) === "br";
        }
      }
      return true;
    };
    if (edge(textNode.previousSibling, "previousSibling") && (!parent || isBlock(parent) || !parent.previousSibling)) text = text.replace(/^ /, "");
    if (edge(textNode.nextSibling, "nextSibling") && (!parent || isBlock(parent) || !parent.nextSibling)) text = text.replace(/ $/, "");
    return text;
  }

  function listMarker(li) {
    const cs = styleOf(li);
    if (!cs || cs.display !== "list-item") return null;
    const type = cs.listStyleType;
    if (!type || type === "none") return null;
    if (type === "disc") return "• ";
    if (type === "circle") return "◦ ";
    if (type === "square") return "▪ ";
    const list = li.parentElement;
    let index = 1;
    if (list && tagOf(list) === "ol") {
      const items = [...list.children].filter((c) => tagOf(c) === "li");
      const start = list.hasAttribute("start") ? Number(list.getAttribute("start")) : 1;
      index = start + items.indexOf(li);
      if (list.reversed) index = (list.hasAttribute("start") ? start : items.length) - items.indexOf(li);
    } else if (list) {
      index = [...list.children].filter((c) => tagOf(c) === "li").indexOf(li) + 1;
    }
    if (li.hasAttribute("value")) index = Number(li.getAttribute("value"));
    const alpha = (n) => {
      let s = "";
      while (n > 0) {
        n--;
        s = String.fromCharCode(97 + (n % 26)) + s;
        n = Math.floor(n / 26);
      }
      return s;
    };
    const roman = (n) => {
      const map = [[1000, "m"], [900, "cm"], [500, "d"], [400, "cd"], [100, "c"], [90, "xc"], [50, "l"], [40, "xl"], [10, "x"], [9, "ix"], [5, "v"], [4, "iv"], [1, "i"]];
      let s = "";
      for (const [v, r] of map) while (n >= v) (s += r), (n -= v);
      return s;
    };
    if (type === "lower-alpha" || type === "lower-latin") return alpha(index) + ". ";
    if (type === "upper-alpha" || type === "upper-latin") return alpha(index).toUpperCase() + ". ";
    if (type === "lower-roman") return roman(index) + ". ";
    if (type === "upper-roman") return roman(index).toUpperCase() + ". ";
    return `${index}. `;
  }

  function isRedundantLabel(el) {
    if (tagOf(el) !== "label") return false;
    const control = el.control;
    if (!control || tagOf(control) !== "input") return false;
    const type = (control.type || "").toLowerCase();
    return type === "checkbox" || type === "radio";
  }

  function referencedIds() {
    const ids = new Set();
    for (const el of document.querySelectorAll("[aria-labelledby], [aria-describedby], [aria-controls], [aria-owns], [aria-details]")) {
      for (const attr of ["aria-labelledby", "aria-describedby", "aria-controls", "aria-owns", "aria-details"]) {
        for (const id of (el.getAttribute(attr) || "").split(/\s+/)) if (id) ids.add(id);
      }
    }
    return ids;
  }

  function keepGeneric(el, ctx) {
    if (el.hasAttribute("aria-label") || el.hasAttribute("aria-labelledby") || el.hasAttribute("title")) return true;
    if (el.hasAttribute("tabindex") || el.hasAttribute("onclick") || isContentEditableHost(el)) return true;
    if (el.id && ctx.referenced.has(el.id)) return true;
    if (isScrollable(el)) return true;
    // Chromium keeps block-level generic containers and drops inline ones.
    return isBlock(el) && (el.id !== "" || el.childNodes.length > 0);
  }

  function axProps(el, role, ctx) {
    const props = {};
    const tag = tagOf(el);
    const type = tag === "input" ? (el.type || "").toLowerCase() : "";
    if (el === ctx.focused) props.focused = true;
    if (role === "heading") {
      const level = /^h[1-6]$/.test(tag) ? Number(tag[1]) : Number(el.getAttribute("aria-level")) || 2;
      props.level = level;
    }
    if (role === "listitem") {
      let level = 0;
      for (let p = el.parentElement; p; p = p.parentElement) if (["ul", "ol", "menu"].includes(tagOf(p))) level++;
      props.level = Math.max(1, level);
    }
    if (role === "treeitem") {
      let level = Number(el.getAttribute("aria-level")) || 0;
      if (!level) for (let p = el.parentElement; p; p = p.parentElement) {
        const r = explicitRole(p);
        if (r === "tree") {
          level++;
          break;
        }
        if (r === "group") level++;
      }
      props.level = Math.max(1, level);
    }
    if (role === "link" || (role === "image" && el.src)) props.url = role === "link" ? el.href : el.src;
    if (type === "checkbox" || type === "radio") props.checked = el.indeterminate ? "mixed" : String(!!el.checked);
    else if (["checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio"].includes(role) && el.hasAttribute("aria-checked")) {
      props.checked = el.getAttribute("aria-checked");
    }
    if (el.hasAttribute("aria-pressed") && role === "button") props.pressed = el.getAttribute("aria-pressed");
    if (el.hasAttribute("aria-expanded")) props.expanded = el.getAttribute("aria-expanded") === "true";
    if (role === "DisclosureTriangle") props.expanded = !!(el.parentElement && el.parentElement.open);
    if (tag === "select" && role === "combobox") {
      props.hasPopup = "menu";
      props.expanded = false;
    } else if (el.hasAttribute("aria-haspopup") && el.getAttribute("aria-haspopup") !== "false") {
      props.hasPopup = el.getAttribute("aria-haspopup") === "true" ? "menu" : el.getAttribute("aria-haspopup");
    }
    if (["tab", "treeitem", "option", "row", "gridcell"].includes(role)) {
      if (tag === "option") props.selected = !!el.selected;
      else if (el.hasAttribute("aria-selected")) props.selected = el.getAttribute("aria-selected") === "true";
      else if (role === "treeitem" || role === "tab") props.selected = false;
    }
    if (isNativeDisabled(el) || el.getAttribute("aria-disabled") === "true") props.disabled = true;
    if (["textbox", "searchbox", "spinbutton"].includes(role) && (tag === "input" || tag === "textarea")) {
      props.settable = !el.readOnly && !el.disabled;
      props.editable = "plaintext";
      props.multiline = tag === "textarea";
    }
    if (role === "slider" && tag === "input") props.settable = true;
    if (isContentEditableHost(el)) props.editable = "richtext";
    const placeholder = el.getAttribute("placeholder");
    if (placeholder && (tag === "input" || tag === "textarea")) props.placeholder = placeholder;
    if (el.hasAttribute("aria-roledescription")) props.roledescription = el.getAttribute("aria-roledescription");
    if (["slider", "progressbar", "meter", "spinbutton", "scrollbar"].includes(role)) {
      if (el.hasAttribute("aria-valuetext")) props.valuetext = el.getAttribute("aria-valuetext");
      else if (tag === "input" && role === "slider") props.valuetext = String(el.value);
      else props.valuetext = "";
    }
    if (el.hasAttribute("aria-description")) props.hasAriaDescription = true;
    return props;
  }

  function axValue(el, role) {
    const tag = tagOf(el);
    if (tag === "input") {
      const type = (el.type || "").toLowerCase();
      if (type === "checkbox" || type === "radio" || type === "submit" || type === "button" || type === "reset" || type === "image") return null;
      if (type === "file") return el.files && el.files.length ? [...el.files].map((f) => f.name).join(", ") : "No file chosen";
      if (type === "range") return String(el.value);
      return el.value;
    }
    if (tag === "textarea") return el.value;
    if (tag === "select") {
      const o = el.options[el.selectedIndex];
      return o ? collapse(o.textContent).trim() : "";
    }
    if (tag === "progress") return el.hasAttribute("value") ? String(Math.round((el.value / (el.max || 1)) * 100)) : null;
    if (["slider", "progressbar", "meter", "spinbutton", "scrollbar"].includes(role) && el.hasAttribute("aria-valuenow")) {
      return el.getAttribute("aria-valuenow");
    }
    if (isContentEditableHost(el)) return collapse(el.innerText || "").trim();
    return null;
  }

  function buildAxNode(el, ctx) {
    const role = chromeRole(el);
    const { name, source } = role === "generic" && !el.hasAttribute("aria-label") && !el.hasAttribute("aria-labelledby") && !el.hasAttribute("title")
      ? { name: "", source: "relatedElement" }
      : accessibleNameSource(el, role);
    const tag = tagOf(el);
    const credential = tag === "input" &&
      CREDENTIAL.test(["type", "autocomplete", "id", "name", "placeholder", "aria-label", "title"].map((a) => el.getAttribute(a) || "").join(" "));
    const node = {
      key: handleFor(el),
      role,
      name,
      nameSource: source,
      value: axValue(el, role),
      description: el.hasAttribute("aria-describedby") ? idrefText(el, "aria-describedby") : null,
      props: axProps(el, role, ctx),
      dom: {
        identifier: el.id || null,
        className: el.getAttribute("class"),
        declaredRole: el.getAttribute("role"),
        tagName: ["input", "select", "textarea"].includes(tag) ? tag : null,
        inputType: tag === "input" ? (el.type || "").toLowerCase() : null,
      },
      children: [],
    };
    if (credential) {
      node.value = null;
      node.description = null;
      delete node.props.valuetext;
      delete node.props.placeholder;
      node.dom = { identifier: null, className: null, declaredRole: null, tagName: null, inputType: null };
      node.credential = true;
    }
    return node;
  }

  function axWalk(node, out, ctx) {
    for (const child of axChildren(node)) {
      if (child.nodeType === 3) {
        if (ctx.skipText) continue;
        const parentStyle = child.parentElement && styleOf(child.parentElement);
        if (parentStyle && (parentStyle.visibility === "hidden" || parentStyle.visibility === "collapse")) continue;
        const text = layoutText(child);
        if (!text || (!/\S/.test(text) && !textRendered(child))) continue;
        if (!/\S/.test(child.nodeValue) && !textRendered(child)) continue;
        const parentEditable = child.parentElement && child.parentElement.isContentEditable;
        const n = { key: handleFor(child), role: "StaticText", name: text, nameSource: "contents", value: null, description: null, props: parentEditable ? { editable: "richtext" } : {}, dom: {}, children: [] };
        out.push(n);
        continue;
      }
      if (child.nodeType !== 1) continue;
      const el = child;
      const tag = tagOf(el);
      if (AX_SKIP.has(tag) || !axRendered(el)) continue;
      if (isRedundantLabel(el)) {
        axWalk(el, out, { ...ctx, skipText: true });
        continue;
      }
      const role = chromeRole(el);
      const visibility = (styleOf(el) || {}).visibility;
      if (visibility === "hidden" || visibility === "collapse" ||
        role === null || role === "none" || role === "presentation" || (role === "generic" && !keepGeneric(el, ctx)) ||
        tag === "tbody" || role === "LineBreak") {
        axWalk(el, out, ctx);
        continue;
      }
      const n = buildAxNode(el, ctx);
      out.push(n);
      if (role === "listitem" || (tag === "li" && (styleOf(el) || {}).display === "list-item")) {
        const marker = listMarker(el);
        if (marker) {
          n.children.push({ key: n.key + ":marker", role: role === "listitem" ? "ListMarker" : "StaticText", name: marker, nameSource: "contents", value: null, description: null, props: {}, dom: role === "listitem" ? {} : null, children: [] });
        }
      }
      if (tag === "select" && role === "combobox") {
        const popup = { key: n.key + ":popup", role: "MenuListPopup", name: "", nameSource: "relatedElement", value: null, description: null, props: {}, dom: null, children: [] };
        for (const option of el.options) {
          popup.children.push({ key: handleFor(option), role: "option", name: collapse(option.textContent).trim(), nameSource: "contents", value: null, description: null, props: { selected: option.selected }, dom: {}, children: [], inMenuList: true });
        }
        n.children.push(popup);
        continue;
      }
      if (tag === "input" || tag === "textarea" || tag === "img" || tag === "iframe" || tag === "frame" || tag === "canvas") {
        if (tag === "iframe" || tag === "frame") ctx.iframes.push({ key: n.key, handle: n.key });
        continue;
      }
      axWalk(el, n.children, { ...ctx, skipText: false });
    }
  }

  function axTree(opts) {
    opts = opts || {};
    const doc = document;
    const active = doc.activeElement;
    const ctx = {
      referenced: referencedIds(),
      focused: active && active !== doc.body && active !== doc.documentElement ? active : null,
      iframes: [],
      skipText: false,
    };
    const root = {
      key: "root",
      role: "RootWebArea",
      name: doc.title || "",
      nameSource: "relatedElement",
      value: null,
      description: null,
      props: { url: String(global.location.href) },
      dom: {},
      children: [],
    };
    if (!ctx.focused && (opts.isMain || opts.focusedFrame)) root.props.focused = true;
    if (doc.body) {
      if (opts.isMain) axWalk(doc.body, root.children, ctx);
      else {
        // Child frames keep their <body> as a generic container (observed in
        // Chromium's tree); the main frame does not.
        const body = { key: handleFor(doc.body), role: "generic", name: "", nameSource: "relatedElement", value: null, description: null, props: {}, dom: { identifier: doc.body.id || null }, children: [] };
        axWalk(doc.body, body.children, ctx);
        root.children.push(body);
      }
    }
    return { root, iframes: ctx.iframes, activeIsFrame: !!(active && ["iframe", "frame"].includes(tagOf(active))) };
  }

  // tab.dom_cua.get_visible_dom() lines (spec section 7); node ids are filled
  // in by the runtime.
  function visibleDomLines(opts) {
    const max = (opts && opts.maxElements) || 200;
    const lines = [];
    const out = [];
    const clean = (s) => String(s).replace(/[\t\n\r\f]+/g, " ").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    const interactive = (el) => {
      const tag = tagOf(el);
      if (["a", "button", "details", "input", "option", "select", "summary", "textarea"].includes(tag)) return true;
      const ce = el.getAttribute("contenteditable");
      if (ce !== null && ce !== "false") return true;
      if (el.hasAttribute("href") || el.hasAttribute("onclick")) return true;
      const role = (el.getAttribute("role") || "").trim().toLowerCase();
      if (["button", "checkbox", "combobox", "link", "menuitem", "option", "radio", "slider", "spinbutton", "switch", "tab", "textbox"].includes(role)) return true;
      const ti = el.getAttribute("tabindex");
      return ti !== null && Number(ti) >= 0;
    };
    const visible = (el) => {
      const cs = styleOf(el);
      if (!cs || cs.visibility !== "visible" || cs.display === "none" || cs.pointerEvents === "none" || Number(cs.opacity) <= 0.01) return false;
      const w = global.innerWidth;
      const h = global.innerHeight;
      return [...el.getClientRects()].some((r) => r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 && r.left < w && r.top < h);
    };
    const textOf = (el) => {
      const parts = [];
      let total = 0;
      const walk = (n) => {
        for (const c of n.nodeType === 1 && n.shadowRoot ? [...n.shadowRoot.childNodes, ...n.childNodes] : n.childNodes) {
          if (total >= 160) return;
          if (c.nodeType === 3) {
            const t = c.nodeValue.replace(/\s+/g, " ").trim();
            if (t) {
              parts.push(t);
              total += t.length + 1;
            }
          } else if (c.nodeType === 1 && !["script", "style", "noscript", "template"].includes(tagOf(c))) walk(c);
        }
      };
      walk(el);
      return parts.join(" ").replace(/\s+/g, " ").trim().slice(0, 160);
    };
    let chars = 0;
    const visit = (el) => {
      if (lines.length >= max) return false;
      if (el.nodeType !== 1) return true;
      if (el.getAttribute("aria-hidden") === "true" || el.hasAttribute("hidden") || el.id === "codex-agent-overlay-root") return true;
      const tag = tagOf(el);
      if (tag === "input" && (el.type || "").toLowerCase() === "hidden") return true;
      if (interactive(el) && visible(el)) {
        let attrs = "";
        for (const a of ["aria-disabled", "aria-label", "contenteditable", "href", "name", "placeholder", "role", "title", "type", "value"]) {
          let v = el.getAttribute(a);
          if (a === "value" && tag === "input") {
            const cred = CREDENTIAL.test(["type", "autocomplete", "id", "name", "placeholder", "aria-label", "title"].map((x) => el.getAttribute(x) || "").join(" "));
            if (cred || (el.type || "").toLowerCase() === "hidden") v = null;
          }
          if (v) attrs += ` ${a}="${clean(v)}"`;
        }
        for (const b of ["checked", "disabled", "multiple", "readonly", "required", "selected"]) if (el.hasAttribute(b)) attrs += ` ${b}="true"`;
        const text = clean(textOf(el));
        const line = text ? `<${tag} node_id=?${attrs}>${text}</${tag}>` : `<${tag} node_id=?${attrs} />`;
        if (chars + line.length + (lines.length ? 1 : 0) > 20000) return false;
        chars += line.length + (lines.length ? 1 : 0);
        lines.push(line);
        out.push(handleFor(el));
      }
      if (el.shadowRoot) for (const c of el.shadowRoot.children) if (!visit(c)) return false;
      for (const c of el.children) if (!visit(c)) return false;
      return true;
    };
    if (document.body) visit(document.body);
    return { lines, handles: out };
  }

  // Playwright's AI snapshot of this frame's body, for domSnapshot().
  function aiSnapshot() {
    const inj = requireInjected();
    const r = inj.incrementalAriaSnapshot(document.body || document.documentElement, { mode: "ai", track: "cmux-dom" });
    const text = typeof r === "string" ? r : r.full;
    const iframes = [];
    for (const el of document.querySelectorAll("iframe, frame")) {
      if (el.getAttribute("aria-hidden") === "true" || !computeVisible(el)) continue;
      const ref = inj._lastAriaSnapshotForQuery ? inj._lastAriaSnapshotForQuery.refs.get(el) : null;
      iframes.push({ handle: handleFor(el), id: el.id || null, name: el.getAttribute("name") || null, ref: ref || null });
    }
    return { text, iframes };
  }

  const agent = {
    version: 1,
    ping: () => "pong",
    handleFor,
    element,
    snapshot,
    deref: (ref) => {
      const el = deref(ref);
      return el ? handleFor(el) : null;
    },
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
    axTree,
    visibleDomLines,
    aiSnapshot,
    roleOf,
    accessibleName,
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
