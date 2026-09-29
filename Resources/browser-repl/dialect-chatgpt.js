// ChatGPT dialect: the `agent` object of the ChatGPT for Chrome browser-use
// runtime (tests/browser-parity/reference/chatgpt-api-surface.txt), built on
// runtime-core. The accessibility text (`tab.ax`) comes from the page agent's
// axSnapshot() and renderChatgptAx() in chatgpt-ax.js, per
// docs/browser-repl/chatgpt-ax-spec.md.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  const core = ns.core;
  const { Buffer } = core;

  const BROWSER = { id: "cmux", name: "cmux", type: "iab", family: "webkit" };

  // ChatGPT options spell timeouts `timeoutMs`; Playwright spells them `timeout`.
  function mapOptions(o) {
    if (!o || typeof o !== "object" || Array.isArray(o) || !("timeoutMs" in o)) return o;
    const { timeoutMs, ...rest } = o;
    return { ...rest, timeout: timeoutMs };
  }
  function wrapPlaywright(value) {
    if (!(value instanceof core.Locator) && !(value instanceof core.FrameLocator)) return value;
    return new Proxy(value, {
      get(target, prop) {
        const v = target[prop];
        if (typeof v !== "function" || typeof prop === "symbol" || prop.startsWith("_")) return v;
        return (...args) => {
          const out = v.apply(target, args.map(mapOptions));
          if (out && typeof out.then === "function") return out.then(wrapPlaywright);
          if (Array.isArray(out)) return out.map(wrapPlaywright);
          return wrapPlaywright(out);
        };
      },
    });
  }

  const CUA_BUTTONS = { 1: "left", 2: "middle", 3: "right", left: "left", right: "right", middle: "middle", wheel: "middle" };
  const CUA_KEYS = {
    BACKSPACE: "Backspace", ENTER: "Enter", RETURN: "Enter", TAB: "Tab", ESC: "Escape", ESCAPE: "Escape", SPACE: " ",
    DELETE: "Delete", DEL: "Delete", HOME: "Home", END: "End", PAGEUP: "PageUp", PAGEDOWN: "PageDown",
    ARROWLEFT: "ArrowLeft", ARROWRIGHT: "ArrowRight", ARROWUP: "ArrowUp", ARROWDOWN: "ArrowDown",
    LEFT: "ArrowLeft", RIGHT: "ArrowRight", UP: "ArrowUp", DOWN: "ArrowDown",
    CTRL: "Control", CONTROL: "Control", SHIFT: "Shift", ALT: "Alt", OPTION: "Alt", META: "Meta", CMD: "Meta",
    COMMAND: "Meta", SUPER: "Meta", WIN: "Meta", CAPSLOCK: "CapsLock", INSERT: "Insert",
  };
  function cuaKey(name) {
    const upper = String(name).toUpperCase();
    if (CUA_KEYS[upper]) return CUA_KEYS[upper];
    if (/^F\d{1,2}$/.test(upper)) return upper;
    return String(name).length === 1 ? String(name).toLowerCase() : String(name);
  }
  // Presses a chord: every key down in order, then up in reverse.
  async function pressChord(page, keys) {
    const names = keys.map(cuaKey);
    for (const k of names) await page.keyboard.down(k);
    for (const k of names.slice().reverse()) await page.keyboard.up(k);
  }

  // ---------------------------------------------------------------------------
  // Accessibility text (docs/browser-repl/chatgpt-ax-spec.md). Clean-room
  // renderer over the tree the page agent builds with axTree().

  const ROLE_TEXT = {
    RootWebArea: "AXWebArea", StaticText: "text", InlineTextBox: "text", ListMarker: "AXListMarker", heading: "heading",
    link: "link", DisclosureTriangle: "button", searchbox: "search text field", checkbox: "checkbox", ToggleButton: "checkbox",
    radio: "radio button", switch: "switch", slider: "slider", spinbutton: "stepper", scrollbar: "scroll bar",
    separator: "splitter", toolbar: "toolbar", menubar: "menu bar", tablist: "tab group", tab: "tab", image: "image",
    Canvas: "image", SvgRoot: "image", list: "content list", listbox: "list", DescriptionList: "definition list",
    table: "table", grid: "table", treegrid: "table", row: "row", treeitem: "row", cell: "cell", gridcell: "cell",
    columnheader: "cell", rowheader: "cell", Column: "column", tree: "outline", MenuListPopup: "menu", menu: "menu",
    Date: "date field", DateTime: "date field", InputTime: "time field", ColorWell: "color well", meter: "level indicator",
    progressbar: "progress indicator", ScrollView: "scroll area", option: "", MenuListOption: "", menuitem: "",
    menuitemcheckbox: "", menuitemradio: "", radiogroup: "",
  };
  const HIDES_DESCENDANTS = new Set(["button", "checkbox", "radio", "switch", "slider", "textbox", "searchbox", "spinbutton",
    "tab", "option", "image", "Canvas", "progressbar", "meter", "StaticText", "ListMarker", "ColorWell", "Date", "DateTime", "InputTime"]);
  const DESCRIPTION_ROLES = new Set(["link", "group", "generic", "radiogroup", "tabpanel"]);
  const SETTABLE_INPUT_TYPES = new Set(["checkbox", "radio", "range", "number", "date", "time", "datetime-local", "month", "week", "color"]);

  function roleText(n) {
    if (n.props.roledescription) return n.props.roledescription;
    if (n.role === "button") {
      if (n.props.pressed !== undefined) return "checkbox";
      if (n.props.hasPopup) return "pop up button";
      return "button";
    }
    if (n.role === "combobox") return n.dom && n.dom.tagName === "select" ? "pop up button" : "combo box";
    if (n.role === "textbox") return n.props.multiline ? "text entry area" : "text field";
    return n.role in ROLE_TEXT ? ROLE_TEXT[n.role] : "container";
  }

  function shortUrl(url) {
    if (!url) return null;
    if (/^data:/i.test(url)) return null;
    if (!/^[a-z][a-z0-9+.-]*:/i.test(url)) return null;
    return url.replace(/^https?:\/\//i, "").replace(/^www\./i, "");
  }

  const TRISTATE = { true: "1", false: "0", mixed: "2" };

  // One node's line parts: role text, states, title and ordered fields.
  function describeAx(n, tabTitle) {
    const role = n.role;
    const name = n.name || "";
    const src = n.nameSource;
    let title = "";
    let description = null;
    let nameAsValue = null;
    if (role === "StaticText" || role === "ListMarker" || role === "option" || role === "MenuListOption") nameAsValue = name;
    else if (role === "RootWebArea") {
      if (src === "attribute") description = name || tabTitle || "";
      else title = name || tabTitle || "";
    } else if (["cell", "gridcell", "columnheader", "rowheader"].includes(role) && src === "contents") title = "";
    else if (src === "placeholder") title = "";
    else if (src === "attribute" || DESCRIPTION_ROLES.has(role) || role === "Iframe" ||
      ((role === "checkbox" || role === "radio") && src === "relatedElement")) description = name || null;
    else title = name;

    let value = null;
    if (role === "heading") value = n.props.level !== undefined ? String(n.props.level) : null;
    else if (["checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio"].includes(role) && n.props.checked !== undefined) value = TRISTATE[n.props.checked] || null;
    else if (role === "button" && n.props.pressed !== undefined) value = TRISTATE[n.props.pressed] || null;
    else if (role === "tab") value = n.props.selected ? "1" : "0";
    else if (role === "link") value = shortUrl(n.props.url);
    else if (nameAsValue !== null) value = nameAsValue;
    else if (role !== "button" && n.value !== null && n.value !== undefined && n.value !== "") value = String(n.value);

    const fields = [];
    const push = (label, v) => {
      if (v === null || v === undefined || v === "") return;
      if (v === title) return;
      fields.push([label, v]);
    };
    push("Description", description);
    if (role === "RootWebArea" || (role !== "link" && n.props.url)) push("URL", shortUrl(n.props.url));
    if (n.props.hasAriaDescription && n.description && n.description !== name) push("Help", n.description);
    push("Value", value);
    if (n.props.valuetext && n.props.valuetext !== value) push("Details", n.props.valuetext);
    if (!n.credential) push("Placeholder", n.props.placeholder);
    push("ID", n.dom && n.dom.identifier);
    if (n.props.expanded === false) push("Secondary Actions", "Expand");
    else if (n.props.expanded === true) push("Secondary Actions", "Collapse");

    const states = [];
    if (n.props.selected === true) states.push("selected");
    else if (n.props.selected === false && !n.inMenuList) states.push("selectable");
    if (n.props.disabled) states.push("disabled");
    if (n.props.expanded === true) states.push("expanded");
    else if (n.props.expanded === false) states.push("collapsed");
    const tag = n.dom && n.dom.tagName;
    const inputType = n.dom && n.dom.inputType;
    const settable = (["textbox", "searchbox", "combobox", "spinbutton"].includes(role) && n.props.settable) ||
      tag === "select" || (tag === "input" && SETTABLE_INPUT_TYPES.has(inputType)) || role === "tab";
    if (settable) states.push("settable");
    if (role === "tab") states.push("boolean");
    else if (tag === "input" && (inputType === "checkbox" || inputType === "radio")) states.push("integer");
    else if (tag === "input" && inputType === "range" && /^-?\d+$/.test(String(n.value))) states.push("integer");

    return { roleText: roleText(n), states, title, fields };
  }

  function lineOf(d) {
    let head = [d.roleText, d.states.length ? `(${d.states.join(", ")})` : "", d.title].filter(Boolean).join(" ");
    const bare = !d.title && d.fields.length === 1 && d.fields[0][0] !== "Secondary Actions";
    if (bare) head += (head ? " " : "") + d.fields[0][1];
    else if (d.fields.length) head += (d.title ? ", " : head ? " " : "") + d.fields.map(([l, v]) => `${l}: ${v}`).join(", ");
    return head;
  }

  function isAnonymousContainer(r, ignoreId) {
    const d = r.d;
    return d.roleText === "container" && !d.title && !d.states.length &&
      d.fields.every(([l]) => ignoreId && l === "ID");
  }

  // Builds the rendered tree: prunes empty nodes, merges adjacent text,
  // collapses and flattens anonymous containers (spec 2.6).
  function shapeAx(tree, tabTitle) {
    const mergeText = (children) => {
      const out = [];
      for (const c of children) {
        const prev = out[out.length - 1];
        if (c.role === "StaticText" && prev && prev.role === "StaticText" && c.dom && prev.dom) {
          out[out.length - 1] = { ...prev, name: `${prev.name} ${c.name}` };
        } else out.push(c);
      }
      return out;
    };
    const shape = (n) => {
      if ((n.role === "StaticText" || n.role === "ListMarker") && !/\S/.test(n.name || "")) return [];
      const d = describeAx(n, tabTitle);
      let kids = n.children || [];
      if (HIDES_DESCENDANTS.has(n.role) && !(n.role === "button" && false)) kids = [];
      else if (n.role === "link") kids = kids.filter((k) => k.role !== "StaticText");
      else if (n.role === "combobox" && !(n.dom && n.dom.tagName === "select")) kids = [];
      const children = mergeText(kids).flatMap(shape);
      const r = { key: n.key, d, children, focused: !!n.props.focused, node: n };
      if (isAnonymousContainer(r, true) && children.length === 1 && !r.focused) return children;
      if (!d.title && !d.fields.length && !d.states.length && !children.length && !["image", "tab"].includes(d.roleText) && n.role !== "RootWebArea") return [];
      return [r];
    };
    const flatten = (r) => {
      r.children.forEach(flatten);
      if (isAnonymousContainer(r, false)) {
        r.children = r.children.flatMap((c) => (isAnonymousContainer(c, false) && !c.focused ? c.children : [c]));
      }
      return r;
    };
    const roots = shape(tree);
    return roots.length ? flatten(roots[0]) : null;
  }

  function lcsPairs(a, b) {
    const n = a.length;
    const m = b.length;
    const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    const pairs = [];
    let i = 0;
    let j = 0;
    while (i < n && j < m) {
      if (a[i] === b[j]) {
        pairs.push([i, j]);
        i++;
        j++;
      } else if (dp[i + 1][j] >= dp[i][j + 1]) i++;
      else j++;
    }
    return pairs;
  }

  function preorder(root, fn, depth = 0) {
    fn(root, depth);
    for (const c of root.children) preorder(c, fn, depth + 1);
  }

  function ranges(ids) {
    const sorted = [...ids].sort((a, b) => a - b);
    const out = [];
    for (let i = 0; i < sorted.length; i++) {
      let j = i;
      while (j + 1 < sorted.length && sorted[j + 1] === sorted[j] + 1) j++;
      out.push(i === j ? String(sorted[i]) : `${sorted[i]}-${sorted[j]}`);
      i = j;
    }
    return out.join(", ");
  }

  const byteLength = (s) => core.utf8Encode(s).length;

  // renderChatgptAx(previousRevision, tree, { tabTitle, mode, minSavedBytes, minSavedRatio })
  //   -> { text, revision }. The header line is added by the caller.
  function renderChatgptAx(prev, tree, options = {}) {
    const root = shapeAx(tree, options.tabTitle);
    if (!root) throw new Error("Accessibility capture was empty");
    const ids = new Map();
    const match = (n, o) => {
      ids.set(n, o.id);
      const pairs = lcsPairs(n.children.map((c) => c.key), o.children.map((c) => c.key));
      for (const [i, j] of pairs) match(n.children[i], o.children[j]);
    };
    if (prev && prev.root && prev.root.key === root.key) match(root, prev.root);
    let next = prev ? Math.max(0, ...ids.values()) + 1 : 0;
    const lines = [];
    let focus = null;
    const nodesById = new Map();
    preorder(root, (r, depth) => {
      if (!ids.has(r)) ids.set(r, next++);
      r.id = ids.get(r);
      r.depth = depth;
      r.line = `${r.id} ${lineOf(r.d)}`;
      nodesById.set(r.id, r);
      lines.push("\t".repeat(depth) + r.line);
      if (r.focused && !focus) focus = r;
    });
    const focusLine = focus ? `The focused UI element is ${focus.line}` : "";
    const full = lines.join("\n") + "\n" + (focusLine ? "\n" + focusLine : "");
    const revision = { root, nodesById };
    if (!prev || options.mode === "full") return { text: full, revision };
    const prevLines = new Map();
    preorder(prev.root, (r) => prevLines.set(r.id, r.line));
    const removed = [...prevLines.keys()].filter((id) => !nodesById.has(id));
    const changes = [];
    preorder(root, (r) => {
      if (!prevLines.has(r.id)) changes.push("+" + "\t".repeat(r.depth) + r.line);
      else if (prevLines.get(r.id) !== r.line) changes.push("~" + "\t".repeat(r.depth) + r.line);
    });
    let candidate;
    if (!changes.length && !removed.length) {
      candidate = "There has been no change in the accessibility tree." + (focusLine ? "\n" + focusLine : "");
    } else {
      candidate = "The following is a diff from the previous accessibility tree with ~ and + representing changed and added elements, respectively. Removed elements are summarized by ID range.\n" +
        (removed.length ? `Removed element IDs: ${ranges(removed)}\n` : "") +
        changes.map((l) => l + "\n").join("") + focusLine;
    }
    const minBytes = options.minSavedBytes !== undefined ? options.minSavedBytes : 1000;
    const minRatio = options.minSavedRatio !== undefined ? options.minSavedRatio : 0.3;
    const fullBytes = byteLength(full);
    const saved = fullBytes - byteLength(candidate);
    return { text: saved >= minBytes && saved / fullBytes >= minRatio ? candidate : full, revision };
  }

  // Captures the tab's AX tree across frames: the page agent builds each
  // frame; child frame roots attach under their <iframe> node.
  async function captureAxTree(page) {
    await page._refreshFrames();
    const main = page.mainFrame();
    const handles = new Map();
    const build = async (frame, isMain, focusedFrame) => {
      const docId = await frame._call("agent", "() => { const g = globalThis; const k = Symbol.for('cmux.browserRepl.docId'); if (!g[k]) Object.defineProperty(g, k, { value: Math.random().toString(36).slice(2), enumerable: false }); return g[k]; }", []);
      const r = await frame._agent("axTree", { isMain, focusedFrame });
      const prefix = (key) => `${docId}:${key}`;
      const visit = (n) => {
        const raw = n.key;
        n.key = prefix(raw);
        if (/^h\d+$/.test(raw)) handles.set(n.key, { frame, handle: raw });
        if (!focusedFrame && !isMain && n.props.focused) delete n.props.focused;
        n.children.forEach(visit);
      };
      visit(r.root);
      for (const { key } of r.iframes) {
        const child = await frame._contentFrame(key).catch(() => null);
        if (!child) continue;
        const owner = findKey(r.root, prefix(key));
        if (!owner) continue;
        const childTree = await build(child, false, r.activeIsFrame).catch(() => null);
        if (childTree) owner.children.push(childTree.root);
      }
      return r;
    };
    const r = await build(main, true, false);
    return { root: r.root, handles };
  }
  function findKey(n, key) {
    if (n.key === key) return n;
    for (const c of n.children) {
      const f = findKey(c, key);
      if (f) return f;
    }
    return null;
  }

  // Synthetic tree while a JavaScript dialog is open (spec 5).
  function dialogTree(page, dialog, promptText) {
    const d = dialog;
    let host = "";
    try {
      host = new core.URL(page.url()).host;
    } catch {}
    const id = `dialog:${d._p.dialogId}`;
    const node = (key, role, name, nameSource, extra = {}) => ({ key: `${id}:${key}`, role, name, nameSource, value: null, description: null, props: {}, dom: null, children: [], ...extra });
    const box = node("box", "alertdialog", host ? `${host} says` : "This page says", "contents", { props: { modal: true } });
    box.children.push(node("message", "StaticText", d.message(), "contents", { dom: {} }));
    const type = d.type();
    const okFocused = type !== "prompt";
    if (type === "prompt") {
      box.children.push(node("prompt", "textbox", "Response", "attribute", { value: promptText, props: { focused: true, settable: true, editable: "plaintext" }, dialogTarget: { control: "prompt" } }));
    }
    if (type === "confirm" || type === "prompt") box.children.push(node("cancel", "button", "Cancel", "contents", { dialogTarget: { control: "dismiss" } }));
    box.children.push(node("ok", "button", "OK", "contents", { props: okFocused ? { focused: true } : {}, dialogTarget: { control: "accept" } }));
    const root = node("root", "RootWebArea", page._title || "Web page", "attribute", { props: { url: page.url() } });
    root.children.push(box);
    return root;
  }

  // Playwright AI snapshot with frames expanded and simplified (spec 8).
  async function domSnapshot(page) {
    await page._refreshFrames();
    const expand = async (frame) => {
      const r = await frame._agent("aiSnapshot");
      let lines = r.text.split("\n");
      for (const f of r.iframes) {
        if (!f.ref) continue;
        const index = lines.findIndex((l) => new RegExp(`^\\s*- iframe.*\\[ref=${f.ref}\\]`).test(l));
        if (index < 0) continue;
        const child = await frame._contentFrame(f.handle).catch(() => null);
        if (!child) continue;
        const inner = await expand(child).catch(() => null);
        const attrs = (f.id ? ` [id=${JSON.stringify(f.id)}]` : "") + (f.name ? ` [name=${JSON.stringify(f.name)}]` : "");
        let line = lines[index].replace(`[ref=${f.ref}]`, `${attrs.trim()} [ref=${f.ref}]`.replace(/^ /, ""));
        if (attrs) line = lines[index].replace(` [ref=${f.ref}]`, `${attrs} [ref=${f.ref}]`);
        if (!line.endsWith(":")) line += ":";
        const indent = /^(\s*)/.exec(line)[1] + "  ";
        lines.splice(index, 1, line, ...(inner ? inner.split("\n").filter(Boolean).map((l) => indent + l) : []));
      }
      return lines.join("\n");
    };
    const text = await expand(page.mainFrame());
    if (!/^\s*- /m.test(text)) return text;
    // Rebuild by indentation, then simplify.
    const rootNode = { line: null, children: [], indent: -1 };
    const stack = [rootNode];
    for (const raw of text.split("\n")) {
      if (!raw.trim()) continue;
      const indent = /^(\s*)/.exec(raw)[1].length;
      while (stack.length > 1 && stack[stack.length - 1].indent >= indent) stack.pop();
      const n = { line: raw.trim(), children: [], indent };
      stack[stack.length - 1].children.push(n);
      stack.push(n);
    }
    const simplify = (n) => {
      const out = [];
      for (const c of n.children) {
        c.line = c.line.replace(/ \[ref=[^\]]*\]/g, "").replace(/ \[cursor=[^\]]*\]/g, "");
        if (/^- img\b/.test(c.line)) continue;
        c.children = simplify(c);
        if (/^- (generic|listitem|group)((\s\[[^\]]*\])*)\s*:?$/.test(c.line)) out.push(...c.children);
        else out.push(c);
      }
      return out;
    };
    const lines = [];
    const render = (n, depth) => {
      for (const c of n.children) {
        lines.push("  ".repeat(depth) + c.line);
        render(c, depth + 1);
      }
    };
    rootNode.children = simplify(rootNode);
    render(rootNode, 0);
    return lines.join("\n");
  }

  const AX_KEYS = { RETURN: "Enter", ESC: "Escape" };

  function createAxApi(tab, session) {
    const page = tab._page;
    let handles = new Map();
    let dialogPrompt = null;
    let dialogShown = null;

    function header(title, url) {
      const t = title === undefined || title === null ? "Unknown" : title;
      const u = url === undefined || url === null ? "Unknown" : url;
      return `Browser tab: ${Number(tab.id)}, Title: ${JSON.stringify(t)}, URL: ${JSON.stringify(u)}.\n`;
    }

    async function capture(options = {}) {
      await page._syncInfo().catch(() => {});
      const dialog = tab._dialog && !tab._dialog._handled ? tab._dialog : null;
      let tree;
      if (dialog) {
        if (dialogShown !== dialog) {
          dialogShown = dialog;
          dialogPrompt = dialog.type() === "prompt" ? dialog.defaultValue() : null;
        }
        tree = dialogTree(page, dialog, dialogPrompt);
        handles = new Map();
      } else {
        dialogShown = null;
        const captured = await captureAxTree(page);
        tree = captured.root;
        handles = captured.handles;
      }
      const { text, revision } = renderChatgptAx(tab._axRevision, tree, {
        tabTitle: page._title,
        mode: options.disableDiffing ? "full" : "auto",
      });
      tab._axRevision = revision;
      let state = header(page._title, page.url()) + text;
      if (dialog && options.withScreenshotNote) {
        state += `\n\nScreenshot unavailable while a JavaScript ${dialog.type()} dialog is open. Use tab.ax.get("state") and tab.ax.click(elementIndex) to interact with its controls.`;
      }
      return state;
    }

    function resolve(index) {
      if (!Number.isSafeInteger(index)) throw new Error(`Accessibility element ${index} is stale or missing`);
      const r = tab._axRevision && tab._axRevision.nodesById.get(index);
      if (!r) throw new Error(`Accessibility element ${index} is stale or missing`);
      if (r.node.dialogTarget) {
        if (!tab._dialog || tab._dialog._handled || !r.key.startsWith(`dialog:${tab._dialog._p.dialogId}:`)) throw new Error("JavaScript dialog is no longer active");
        return { dialog: tab._dialog, control: r.node.dialogTarget.control, r };
      }
      if (tab._dialog && !tab._dialog._handled) throw new Error("A JavaScript dialog is blocking the requested page element");
      const h = handles.get(r.key);
      if (!h) throw new Error(`Accessibility element ${index} does not support programmatic activation`);
      return { locator: new core.ElementHandle(h.frame, h.handle), r };
    }

    async function answerDialog(t, accept) {
      tab._dialog = null;
      if (accept) await t.dialog.accept(t.dialog.type() === "prompt" ? dialogPrompt || "" : undefined);
      else await t.dialog.dismiss();
    }

    const point = (target) => (Array.isArray(target) ? { x: target[0], y: target[1] } : target);

    return {
      async get(mode = "state", options = {}) {
        if (mode === "screenshot") return tab.screenshot({});
        if (mode === "both") {
          const dialogOpen = !!(tab._dialog && !tab._dialog._handled);
          const state = await capture({ ...options, withScreenshotNote: dialogOpen });
          return dialogOpen ? { state } : { screenshot: await tab.screenshot({}), state };
        }
        return capture(options);
      },
      async write(mode = "state", options = {}) {
        const r = await this.get(mode, options);
        const out = typeof r === "string" ? r : r instanceof Uint8Array ? `[screenshot ${r.length} bytes]` : r.state + (r.screenshot ? `\n[screenshot ${r.screenshot.length} bytes]` : "");
        session.host.console.log(out);
      },
      async click(target, options = {}) {
        if (typeof target === "number") {
          const t = resolve(target);
          if (t.dialog) {
            if (t.control === "prompt") return;
            return answerDialog(t, t.control === "accept" && t.dialog.type() !== "alert");
          }
          if (options.clickCount === 2) return t.locator.dblclick({ button: options.button });
          return t.locator.click({ button: options.button, clickCount: options.clickCount });
        }
        const p = point(target);
        if (!p || typeof p.x !== "number") throw new Error("Accessibility action requires an element index or point");
        if (tab._dialog && !tab._dialog._handled) throw new Error("JavaScript dialog controls have no viewport coordinates; use an accessibility element index with tab.ax.click(elementIndex)");
        const vp = (await page._syncInfo()).viewport;
        if (p.x < 0 || p.y < 0 || p.x > vp.width || p.y > vp.height) throw new Error("Coordinate is outside the active tab content viewport");
        await page.mouse.click(p.x, p.y, { clickCount: options.clickCount || 1, button: options.button || "left" });
      },
      async drag(from, to) {
        const a = point(from);
        const b = point(to);
        await session.call("input.drag", { targetId: page._targetId, path: [a, b], button: "left", modifiers: [] });
        await page._afterAction();
      },
      async setValue(index, value) {
        const t = resolve(index);
        if (t.dialog) {
          if (t.control !== "prompt") throw new Error(`Accessibility element ${index} has no settable value`);
          dialogPrompt = String(value);
          return;
        }
        const n = t.r.node;
        if (n.role === "tab") {
          await t.locator.click();
          return;
        }
        if (n.dom && n.dom.tagName === "select") {
          await t.locator.selectOption({ label: String(value) }).catch(() => t.locator.selectOption(String(value)));
          return;
        }
        if (n.dom && n.dom.inputType && ["checkbox", "radio"].includes(n.dom.inputType)) {
          await t.locator.setChecked(!!Number(value) || value === true || value === "true");
          return;
        }
        if (n.dom && n.dom.inputType === "range") {
          await t.locator.evaluate((el, v) => {
            el.value = v;
            el.dispatchEvent(new Event("input", { bubbles: true }));
            el.dispatchEvent(new Event("change", { bubbles: true }));
          }, String(value));
          return;
        }
        if (!(n.props.settable || n.props.editable)) throw new Error(`Accessibility element ${index} has no settable value`);
        await t.locator.fill(String(value));
      },
      async typeText(index, text) {
        if (index !== null && index !== undefined) {
          const t = resolve(index);
          if (t.dialog) {
            if (t.control !== "prompt") throw new Error(`Accessibility element ${index} has no settable value`);
            dialogPrompt = (dialogPrompt || "") + text;
            return;
          }
          await t.locator.focus();
          await t.locator.evaluate((el) => {
            if (typeof el.setSelectionRange === "function" && typeof el.value === "string") el.setSelectionRange(el.value.length, el.value.length);
          });
        }
        await page.keyboard.type(String(text));
        await page._afterAction();
      },
      async pressKey(index, key) {
        const keys = String(key).split("+").map((k) => AX_KEYS[k.toUpperCase()] || cuaKey(k));
        if (tab._dialog && !tab._dialog._handled) {
          const dialogIndex = index === null || index === undefined ? null : resolve(index);
          const k = keys[keys.length - 1];
          if (k === "Enter") return answerDialog(dialogIndex || { dialog: tab._dialog }, !(dialogIndex && dialogIndex.control === "dismiss") && tab._dialog.type() !== "alert");
          if (k === "Escape") return answerDialog({ dialog: tab._dialog }, false);
          throw new Error("A JavaScript dialog is active; interact with its controls first");
        }
        if (index !== null && index !== undefined) await resolve(index).locator.focus();
        await pressChord(page, keys);
        await page._afterAction();
      },
      async scroll(target, direction, pages = 1) {
        const dx = direction === "left" ? -1 : direction === "right" ? 1 : 0;
        const dy = direction === "up" ? -1 : direction === "down" ? 1 : 0;
        if (typeof target === "number") {
          const t = resolve(target);
          await t.locator.evaluate((el, d) => {
            let s = el;
            const scrollable = (e) => e && (e.scrollHeight > e.clientHeight + 1 || e.scrollWidth > e.clientWidth + 1) && /(auto|scroll|overlay)/.test(getComputedStyle(e).overflow + getComputedStyle(e).overflowY + getComputedStyle(e).overflowX);
            while (s && !scrollable(s)) s = s.parentElement;
            const target = s || document.scrollingElement;
            const w = s ? s.clientWidth : innerWidth;
            const h = s ? s.clientHeight : innerHeight;
            target.scrollBy({ left: d.dx * w * d.pages, top: d.dy * h * d.pages, behavior: "instant" });
          }, { dx, dy, pages });
          return;
        }
        const p = point(target);
        const vp = (await page._syncInfo()).viewport;
        await page.mouse.move(p.x, p.y);
        await page.mouse.wheel(dx * vp.width * pages, dy * vp.height * pages);
      },
      async selectText(index, text, options = {}) {
        const t = resolve(index);
        await t.locator.evaluate((el, o) => {
          el.focus();
          if (typeof el.setSelectionRange === "function" && typeof el.value === "string") {
            const at = o.text ? el.value.indexOf(o.text) : el.value.length;
            if (at < 0) throw new Error(`Text "${o.text}" not found`);
            const end = o.text ? at + o.text.length : at;
            if (o.position === "start") el.setSelectionRange(at, at);
            else if (o.position === "end") el.setSelectionRange(end, end);
            else el.setSelectionRange(at, end);
            return;
          }
          const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
          for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            const at = n.nodeValue.indexOf(o.text);
            if (at >= 0) {
              const range = document.createRange();
              range.setStart(n, o.position === "end" ? at + o.text.length : at);
              range.setEnd(n, o.position === "start" ? at : at + o.text.length);
              const sel = getSelection();
              sel.removeAllRanges();
              sel.addRange(range);
              return;
            }
          }
          throw new Error(`Text "${o.text}" not found`);
        }, { text: String(text), position: options.position });
      },
      async performSecondaryAction(index, action) {
        const t = resolve(index);
        const expanded = t.r.node.props.expanded;
        const offered = expanded === false ? "Expand" : expanded === true ? "Collapse" : null;
        if (!offered || action !== offered) throw new Error(`Accessibility element ${index} does not support secondary action "${action}"`);
        await t.locator.click();
      },
      async paste(index, text) {
        await session.call("clipboard.write", { targetId: page._targetId, items: [{ type: "text/plain", base64: Buffer.from(String(text)).toString("base64") }] });
        if (index !== null && index !== undefined) await resolve(index).locator.focus();
        await page.keyboard.insertText(String(text));
        await page._afterAction();
      },
    };
  }

  ns.chatgptAx = { renderChatgptAx, describeAx, lineOf, shapeAx, captureAxTree, createAxApi, domSnapshot, shortUrl };

  function createChatgptGlobals(session, options = {}) {
    const host = session.host;
    const tabsById = new Map();
    const tabOfPage = new Map();
    let nextTabId = 1;
    let selected = null;

    function tabFor(page) {
      let tab = tabOfPage.get(page);
      if (!tab) {
        tab = new Tab(page, String(nextTabId++));
        tabOfPage.set(page, tab);
        tabsById.set(tab.id, tab);
      }
      return tab;
    }

    class Tab {
      constructor(page, id) {
        this._page = page;
        this.id = id;
        this._logs = [];
        this._dialog = null;
        this._axRevision = null;
        page.on("console", (m) => {
          const type = m.type();
          this._logs.push({ level: type === "warning" ? "warn" : type, message: m.text(), timestamp: host.now ? host.now() : Date.now() });
        });
        // ChatGPT keeps dialogs open until the agent answers them.
        page.on("dialog", (d) => {
          this._dialog = d;
        });
        page.on("close", () => {
          tabsById.delete(this.id);
          tabOfPage.delete(page);
          if (selected === this) selected = null;
        });
        this.playwright = createPlaywrightApi(this);
        this.cua = createCuaApi(this);
        this.dom_cua = createDomCuaApi(this);
        this.clipboard = createClipboardApi(this);
        this.dev = { logs: async (o = {}) => this._devLogs(o) };
        this.content = createContentApi(this);
        this.capabilities = createCapabilities(this);
        this.ax = createAxApi(this, session);
      }
      async _devLogs({ levels, limit, filter } = {}) {
        let logs = this._logs.slice();
        if (levels && levels.length) logs = logs.filter((l) => levels.includes(l.level));
        if (filter) logs = logs.filter((l) => l.message.includes(filter));
        if (limit) logs = logs.slice(-limit);
        return logs;
      }
      async goto(url) {
        await this._page.goto(url);
        selected = this;
      }
      async back() {
        await this._page.goBack();
      }
      async forward() {
        await this._page.goForward();
      }
      async reload() {
        await this._page.reload();
      }
      async close() {
        await this._page.close();
      }
      async title() {
        if (this._page.isClosed()) return undefined;
        return this._page.title();
      }
      async url() {
        if (this._page.isClosed()) return undefined;
        await this._page._syncInfo().catch(() => {});
        return this._page.url();
      }
      async screenshot(o = {}) {
        const buf = await this._page.screenshot({ fullPage: !!o.fullPage, type: o.format === "jpeg" ? "jpeg" : "png", clip: o.clip });
        return new Uint8Array(buf);
      }
      async getJsDialog() {
        const d = this._dialog;
        if (!d || d._handled) {
          this._dialog = null;
          return undefined;
        }
        const tab = this;
        const done = () => {
          tab._dialog = null;
        };
        const base = { type: d.type(), message: d.message() };
        if (d.type() === "prompt") base.defaultValue = d.defaultValue();
        base.dismiss = async () => {
          done();
          await d.dismiss();
        };
        if (d.type() === "confirm" || d.type() === "prompt" || d.type() === "beforeunload") {
          base.accept = async (text) => {
            done();
            await d.accept(text);
          };
        }
        return base;
      }
      async markDeliverable() {}
      async markHandoff() {}
      async requestManualHandoff() {
        throw new Error("Manual handoff is only available for Cloud Browser tabs");
      }
    }

    function createPlaywrightApi(tab) {
      const page = tab._page;
      const api = {
        locator: (s, o) => wrapPlaywright(page.locator(s, o)),
        getByRole: (r, o) => wrapPlaywright(page.getByRole(r, o)),
        getByText: (t, o) => wrapPlaywright(page.getByText(t, o)),
        getByLabel: (t, o) => wrapPlaywright(page.getByLabel(t, o)),
        getByPlaceholder: (t, o) => wrapPlaywright(page.getByPlaceholder(t, o)),
        getByTestId: (t) => wrapPlaywright(page.getByTestId(t)),
        frameLocator: (s) => wrapPlaywright(page.frameLocator(s)),
        // Read-only page scope: the function runs in the page world, and the
        // agent is expected not to mutate. Enforcement matches ChatGPT's
        // contract only as far as documentation goes.
        evaluate: (fn, arg) => page.evaluate(fn, arg),
        waitForEvent: (event, o) => page.waitForEvent(event, mapOptions(o)),
        waitForLoadState: (o) => (typeof o === "string" ? page.waitForLoadState(o) : page.waitForLoadState(o && o.state, mapOptions(o))),
        waitForTimeout: (ms) => page.waitForTimeout(ms),
        waitForURL: (url, o) => page.waitForURL(url, mapOptions(o)),
        async expectNavigation(action, o = {}) {
          const start = page.url();
          const result = await action();
          await core.poll(session, o.timeoutMs !== undefined ? o.timeoutMs : session.defaultNavigationTimeout, "expectNavigation", async () => {
            const info = await page._syncInfo();
            return { done: info.url !== start && (o.url === undefined || core.urlMatches("", info.url, o.url)) };
          });
          await page.waitForLoadState(o.waitUntil || "load");
          return result;
        },
        async domSnapshot() {
          return domSnapshot(page);
        },
        async elementInfo({ x, y } = {}) {
          return page.evaluate(({ x, y }) => {
            return document.elementsFromPoint(x, y).slice(0, 5).map((el) => ({
              tagName: el.tagName.toLowerCase(),
              id: el.id || undefined,
              text: (el.innerText || "").trim().slice(0, 200),
              selector: el.id ? `#${CSS.escape(el.id)}` : el.tagName.toLowerCase(),
            }));
          }, { x, y });
        },
        async elementScreenshot(o = {}) {
          return tab.screenshot(o);
        },
      };
      return api;
    }

    function createCuaApi(tab) {
      const page = tab._page;
      const button = (b) => CUA_BUTTONS[b === undefined ? 1 : b] || "left";
      const withKeys = async (keys, fn) => {
        const names = (keys || []).map(cuaKey);
        for (const k of names) await page.keyboard.down(k);
        try {
          return await fn();
        } finally {
          for (const k of names.slice().reverse()) await page.keyboard.up(k);
        }
      };
      return {
        click: ({ x, y, button: b, keys } = {}) => withKeys(keys, () => page.mouse.click(x, y, { button: button(b) })),
        double_click: ({ x, y, keys } = {}) => withKeys(keys, () => page.mouse.dblclick(x, y)),
        move: ({ x, y, keys } = {}) => withKeys(keys, () => page.mouse.move(x, y)),
        async drag({ path, keys } = {}) {
          if (!path || path.length < 2) throw new Error("drag requires a path with at least two points");
          await withKeys(keys, () => session.call("input.drag", { targetId: page._targetId, path: path.map((p) => ({ x: p.x, y: p.y })), button: "left", modifiers: [] }));
          await page._afterAction();
        },
        async scroll({ x, y, scrollX = 0, scrollY = 0, keys } = {}) {
          await withKeys(keys, async () => {
            await page.mouse.move(x, y);
            await page.mouse.wheel(scrollX, scrollY);
          });
        },
        type: async ({ text } = {}) => {
          await page.keyboard.type(String(text));
          await page._afterAction();
        },
        keypress: async ({ keys } = {}) => {
          await pressChord(page, keys || []);
          await page._afterAction();
        },
        downloadMedia: async ({ x, y } = {}) => {
          await page.mouse.click(x, y, { modifiers: ["Alt"] });
        },
      };
    }

    function createDomCuaApi(tab) {
      const page = tab._page;
      let nodeMap = new Map();
      let nextNode = 1;
      const nodeFor = async (id) => {
        const entry = nodeMap.get(Number(id));
        if (!entry) throw new Error(`DOM node ${id} is stale or missing`);
        return entry;
      };
      const locatorFor = (entry) => new core.ElementHandle(entry.frame, entry.handle);
      return {
        async get_visible_dom() {
          const main = page.mainFrame();
          const { lines, handles } = await main._agent("visibleDomLines", {});
          if (nodeMap.size > 5000 || page._domCuaDocument !== page.url()) {
            nodeMap = new Map();
            nextNode = 1;
            page._domCuaDocument = page.url();
          }
          const idOf = new Map([...nodeMap].map(([id, e]) => [e.handle, id]));
          return lines.map((line, i) => {
            let id = idOf.get(handles[i]);
            if (!id) {
              id = nextNode++;
              nodeMap.set(id, { frame: main, handle: handles[i] });
            }
            return line.replace("node_id=?", `node_id=${id}`);
          }).join("\n");
        },
        click: async ({ node_id } = {}) => locatorFor(await nodeFor(node_id)).click(),
        double_click: async ({ node_id } = {}) => locatorFor(await nodeFor(node_id)).dblclick(),
        keypress: async ({ keys } = {}) => pressChord(page, keys || []),
        type: async ({ text } = {}) => page.keyboard.type(String(text)),
        async scroll({ node_id, scrollX = 0, scrollY = 0 } = {}) {
          if (node_id === undefined) {
            await page.evaluate(({ x, y }) => window.scrollBy(x, y), { x: scrollX, y: scrollY });
            return;
          }
          await locatorFor(await nodeFor(node_id)).evaluate((el, d) => el.scrollBy(d.x, d.y), { x: scrollX, y: scrollY });
        },
        downloadMedia: async ({ node_id } = {}) => locatorFor(await nodeFor(node_id)).click({ modifiers: ["Alt"] }),
      };
    }

    function createClipboardApi(tab) {
      const call = (method, params) => session.call(method, { targetId: tab._page._targetId, ...params });
      return {
        async read() {
          const { items } = await call("clipboard.read", {});
          return (items || []).map((i) => ({ type: i.type, data: new Uint8Array(Buffer.from(i.base64, "base64")) }));
        },
        async readText() {
          const { items } = await call("clipboard.read", {});
          const text = (items || []).find((i) => i.type === "text/plain");
          return text ? Buffer.from(text.base64, "base64").toString("utf8") : "";
        },
        async write(items) {
          await call("clipboard.write", {
            items: items.map((i) => ({
              type: i.type,
              base64: typeof i.data === "string" ? Buffer.from(i.data).toString("base64") : Buffer.from(i.data || i.text || "").toString("base64"),
            })),
          });
        },
        async writeText(text) {
          await call("clipboard.write", { items: [{ type: "text/plain", base64: Buffer.from(String(text)).toString("base64") }] });
        },
      };
    }

    function createContentApi(tab) {
      return {
        async export() {
          const text = await tab._page.evaluate(() => (document.body ? document.body.innerText : ""));
          if (!session.files) throw new Error("Content export needs a working directory");
          const name = `./artifacts/tab-${tab.id}-${Date.now()}.txt`;
          await session.files.write(name, Buffer.from(text));
          return name;
        },
        async exportGsuite() {
          throw new Error("Google Workspace export is not supported in cmux");
        },
        async exportYouTubeTranscript() {
          throw new Error("YouTube transcript export is not supported in cmux");
        },
      };
    }

    function capabilityCollection(entries) {
      return {
        async list() {
          return Object.keys(entries);
        },
        async get(id) {
          if (!entries[id]) throw new Error(`Capability "${id}" is not available`);
          return entries[id];
        },
      };
    }

    function createCapabilities(tab) {
      const page = tab._page;
      const entries = {
        viewport: {
          documentation: async () => "viewport.get() returns {width, height}; viewport.set({width, height}) resizes the tab viewport; viewport.reset() restores it.",
          get: async () => (await page._syncInfo()).viewport,
          set: async ({ width, height }) => page.setViewportSize({ width, height }),
          reset: async () => session.call("tab.setViewport", { targetId: page._targetId, reset: true }),
        },
        visibility: {
          documentation: async () => "visibility.get() returns the document visibility state.",
          get: async () => page.evaluate(() => document.visibilityState),
        },
      };
      const caps = session.driver.capabilities ? session.driver.capabilities() : [];
      if (caps.includes("cdp")) {
        entries.cdp = {
          documentation: async () => "cdp.send(method, params) sends a raw Chrome DevTools Protocol command.",
          send: (method, params) => session.call("cdp.send", { targetId: page._targetId, method, params }),
        };
      }
      return capabilityCollection(entries);
    }

    const tabs = {
      async list() {
        const infos = await session.call("tabs.list", {});
        return infos.filter((t) => {
          const page = session.pages.get(t.targetId);
          return page && tabOfPage.has(page);
        }).map((t) => ({ id: tabOfPage.get(session.pages.get(t.targetId)).id, title: t.title, url: t.url, active: tabOfPage.get(session.pages.get(t.targetId)) === selected }));
      },
      async new() {
        const page = await session.newPage(undefined);
        const tab = tabFor(page);
        selected = tab;
        return tab;
      },
      async get(id) {
        const tab = tabsById.get(String(id));
        if (!tab) throw new Error(`Tab ${id} not found`);
        return tab;
      },
      async selected() {
        return selected || undefined;
      },
      async content({ urls, url, maxChars } = {}) {
        const list = urls || (url ? [url] : []);
        const out = [];
        for (const u of list) {
          const page = await session.newPage(u, { background: true });
          try {
            await page.waitForLoadState("load").catch(() => {});
            const text = await page.evaluate(() => (document.body ? document.body.innerText : ""));
            out.push({ url: page.url(), title: await page.title(), content: maxChars ? text.slice(0, maxChars) : text });
          } finally {
            await page.close().catch(() => {});
          }
        }
        return out;
      },
    };

    const user = {
      async openTabs() {
        const infos = await session.call("tabs.list", {});
        return infos.filter((t) => {
          const page = session.pages.get(t.targetId);
          return !page || !tabOfPage.has(page);
        }).map((t) => ({ id: t.targetId, title: t.title, url: t.url, active: !!t.active }));
      },
      async claimTab(tabOrId) {
        const id = typeof tabOrId === "string" ? tabOrId : tabOrId.id;
        const tab = tabFor(session.pageFor(id));
        await tab._page._syncInfo().catch(() => {});
        return tab;
      },
      async getTabContext(tabOrId) {
        const id = typeof tabOrId === "string" ? tabOrId : tabOrId.id;
        const page = session.pageFor(id);
        const info = await page._syncInfo();
        const text = await page.evaluate(() => (document.body ? document.body.innerText : "")).catch(() => "");
        return { title: info.title, url: info.url, content: text.slice(0, 20000) };
      },
    };

    const browser = {
      browserId: BROWSER.id,
      tabs,
      user,
      capabilities: capabilityCollection({}),
      async documentation() {
        return "cmux browser (WebKit). Tabs: browser.tabs.new(), tab.goto(url), tab.ax.write(), tab.playwright.*, tab.cua.*.";
      },
      async history() {
        throw new Error("Browser history is not available for this browser");
      },
      async nameSession(name) {
        session.name = String(name);
      },
    };

    const browsers = {
      async list() {
        return [{ ...BROWSER }];
      },
      async get(id) {
        if (id !== BROWSER.id && id !== BROWSER.type) throw new Error(`Browser "${id}" is not available`);
        return browser;
      },
      async getDefault() {
        return browser;
      },
      async getForUrl() {
        return browser;
      },
    };

    const agent = {
      browsers,
      documentation: {
        async get(name) {
          const text = host.readResource ? host.readResource(`docs/${name}.md`) : null;
          if (!text) throw new Error(`Documentation "${name}" not found`);
          return text;
        },
      },
    };
    return { agent };
  }

  ns.chatgpt = { createChatgptGlobals, cuaKey, mapOptions, renderChatgptAx };
})(typeof globalThis !== "undefined" ? globalThis : this);
