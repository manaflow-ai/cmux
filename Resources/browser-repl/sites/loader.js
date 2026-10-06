// cmux browser REPL site tools: the `sites` global
// (docs/browser-repl/site-tools.md). Each file in sites/ registers one tool
// with register(name, factory); createSites builds them for a REPL session.
//
// Rules every tool follows:
// - It runs through the user's signed-in cmux browser session: the REPL
//   `fetch` (cookie-bearing), or a background tab of the same profile where
//   the call runs in the page's own world, same-origin. A token a site keeps
//   in the page stays in the page; no tool returns a credential.
// - Reads run directly. A write that reaches other people returns a draft;
//   only `tool.method(draftId, { confirm: true })` performs it, through the
//   commit protocol (createDrafts): the draft's typed intent is read back
//   from the site right before the write, which runs only when it matches.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  // Built-ins the commit checks use, captured when the loader runs: code
  // that changes these globals later (agent code shares this realm) does
  // not change how a read-back is copied or compared.
  const stringify = JSON.stringify;
  const objectKeys = Object.keys;
  const getPrototypeOf = Object.getPrototypeOf;
  const ownNames = Object.getOwnPropertyNames;
  const ownDescriptor = Object.getOwnPropertyDescriptor;
  const isArray = Array.isArray;
  const defineProperty = Object.defineProperty;
  const objectTag = Function.prototype.call.bind(Object.prototype.toString);
  const numberIsFinite = Number.isFinite;
  const registry = [];
  const shared = {};

  // meta: { summary, writes: [method names] }. A tool's writes are the
  // methods that change what other people see; each returns a draft and
  // performs it through the commit protocol (see createDrafts).
  function register(name, factory, meta = {}) {
    const at = registry.findIndex((r) => r.name === name);
    const entry = { name, factory, summary: meta.summary || "", writes: Object.freeze([...(meta.writes || [])]) };
    if (at >= 0) registry[at] = entry;
    else registry.push(entry);
  }

  class SiteError extends Error {
    constructor(code, message) {
      super(message);
      this.name = "SiteError";
      this.code = code;
    }
  }

  // Page-side Markdown for one element (a subset of api.pageMarkdown that
  // takes a root). Kept as source so tools can compose page functions with it.
  const ELEMENT_MARKDOWN = `function elementMarkdown(rootEl) {
    if (!rootEl) return "";
    const skip = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS", "IFRAME", "BUTTON"]);
    const clean = (t) => t.replace(/\\s+/g, " ");
    const hidden = (el) => { const cs = getComputedStyle(el); return cs.display === "none" || cs.visibility === "hidden"; };
    const inline = (node) => {
      if (node.nodeType === 3) return clean(node.textContent);
      if (node.nodeType !== 1 || skip.has(node.tagName) || hidden(node)) return "";
      const inner = [...node.childNodes].map(inline).join("");
      const t = inner.trim();
      if (node.tagName === "A" && node.getAttribute("href")) return t ? "[" + t + "](" + node.href + ")" : "";
      if (node.tagName === "B" || node.tagName === "STRONG") return t ? "**" + t + "**" : "";
      if (node.tagName === "EM" || node.tagName === "I") return t ? "*" + t + "*" : "";
      if (node.tagName === "CODE") return "\`" + inner + "\`";
      if (node.tagName === "IMG") return node.alt ? "![" + node.alt + "](" + node.src + ")" : "";
      if (node.tagName === "BR") return "\\n";
      return inner;
    };
    const out = [];
    const BLOCK = /^(DIV|P|H[1-6]|UL|OL|TABLE|SECTION|ARTICLE|MAIN|NAV|HEADER|FOOTER|ASIDE|FORM|PRE|BLOCKQUOTE|DETAILS|FIELDSET|FIGURE|LI)$/;
    const block = (node, depth) => {
      if (node.nodeType === 3) { const t = clean(node.textContent).trim(); if (t) out.push(t); return; }
      if (node.nodeType !== 1 || skip.has(node.tagName) || hidden(node)) return;
      const tag = node.tagName;
      const m = /^H([1-6])$/.exec(tag);
      if (m) return void out.push("#".repeat(Number(m[1])) + " " + inline(node).trim());
      if (tag === "P") { const t = inline(node).trim(); if (t) out.push(t); return; }
      if (tag === "PRE") return void out.push("\`\`\`\\n" + node.innerText + "\\n\`\`\`");
      if (tag === "UL" || tag === "OL") {
        let n = 0;
        for (const li of node.children) if (li.tagName === "LI") out.push("  ".repeat(depth) + (tag === "OL" ? (++n) + "." : "-") + " " + inline(li).trim());
        return;
      }
      if (tag === "TABLE") {
        const rows = [...node.rows].map((r) => "| " + [...r.cells].map((c) => inline(c).trim().replace(/\\|/g, "\\\\|")).join(" | ") + " |");
        if (rows.length) out.push([rows[0], "| " + [...node.rows[0].cells].map(() => "---").join(" | ") + " |", ...rows.slice(1)].join("\\n"));
        return;
      }
      if (tag === "BLOCKQUOTE") return void out.push("> " + inline(node).trim());
      if (![...node.children].some((c) => BLOCK.test(c.tagName))) { const t = inline(node).trim(); if (t) out.push(t); return; }
      for (const c of node.childNodes) block(c, depth);
    };
    block(rootEl, 0);
    return out.filter(Boolean).join("\\n\\n");
  }`;

  // A page function built from source parts. Its toString() is its source,
  // so page.evaluate runs it in the page's world (under the page's CSP, which
  // does not apply to the evaluation itself).
  function pageFunction(body, ...helpers) {
    // eslint-disable-next-line no-new-func
    return new Function("arg", `${helpers.join("\n")}\nreturn (async () => {\n${body}\n})();`);
  }

  // A JavaScript string literal starting at html[i] (quote included), decoded.
  function stringLiteral(html, i) {
    const quote = html[i];
    let out = "";
    for (let j = i + 1; j < html.length; j++) {
      const c = html[j];
      if (c === quote) return out;
      if (c !== "\\") {
        out += c;
        continue;
      }
      const n = html[++j];
      if (n === "x") (out += String.fromCharCode(parseInt(html.substr(j + 1, 2), 16))), (j += 2);
      else if (n === "u") (out += String.fromCharCode(parseInt(html.substr(j + 1, 4), 16))), (j += 4);
      else out += { n: "\n", r: "\r", t: "\t", b: "\b", f: "\f", v: "\v", 0: "\0" }[n] !== undefined ? { n: "\n", r: "\r", t: "\t", b: "\b", f: "\f", v: "\v", 0: "\0" }[n] : n;
    }
    return null;
  }

  // The value of `name = {...}`, `name({...})` or `name = '<escaped JSON>'`
  // (YouTube's mobile pages) embedded in an HTML page, as JSON.
  function embeddedJSON(html, marker) {
    let at = html.indexOf(marker);
    while (at >= 0) {
      const lead = /^\s*(['"])/.exec(html.slice(at + marker.length, at + marker.length + 8));
      if (lead) {
        const text = stringLiteral(html, at + marker.length + lead[0].length - 1);
        try {
          return JSON.parse(text);
        } catch {}
        at = html.indexOf(marker, at + marker.length);
        continue;
      }
      const start = html.indexOf("{", at + marker.length);
      if (start < 0) return null;
      let depth = 0;
      let inString = false;
      for (let i = start; i < html.length; i++) {
        const c = html[i];
        if (inString) {
          if (c === "\\") i++;
          else if (c === '"') inString = false;
          continue;
        }
        if (c === '"') inString = true;
        else if (c === "{") depth++;
        else if (c === "}" && --depth === 0) {
          try {
            return JSON.parse(html.slice(start, i + 1));
          } catch {
            break;
          }
        }
      }
      at = html.indexOf(marker, at + marker.length);
    }
    return null;
  }

  const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", "#39": "'" };
  function decodeEntities(s) {
    return String(s).replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (m, e) => {
      if (e[0] === "#") return String.fromCodePoint(e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
      return ENTITIES[e.toLowerCase()] !== undefined ? ENTITIES[e.toLowerCase()] : m;
    });
  }

  // RFC 4180 CSV to rows of strings.
  function parseCSV(text, sep = ",") {
    const rows = [];
    let row = [];
    let field = "";
    let quoted = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (quoted) {
        if (c === '"' && text[i + 1] === '"') {
          field += '"';
          i++;
        } else if (c === '"') quoted = false;
        else field += c;
      } else if (c === '"' && field === "") quoted = true;
      else if (c === sep) {
        row.push(field);
        field = "";
      } else if (c === "\n" || c === "\r") {
        if (c === "\r" && text[i + 1] === "\n") i++;
        row.push(field);
        rows.push(row);
        row = [];
        field = "";
      } else field += c;
    }
    if (field !== "" || row.length) {
      row.push(field);
      rows.push(row);
    }
    return rows;
  }

  // "B2:D10" -> { c0, r0, c1, r1 } (0-based, inclusive); open ends allowed ("A:C", "3:9").
  function parseA1Range(range) {
    const m = /^([A-Z]*)(\d*)(?::([A-Z]*)(\d*))?$/i.exec(String(range).trim());
    if (!m) throw new SiteError("invalid", `range: expected A1 notation such as "A1:C10", got ${JSON.stringify(range)}`);
    const col = (s) => (s ? [...s.toUpperCase()].reduce((n, ch) => n * 26 + ch.charCodeAt(0) - 64, 0) - 1 : null);
    const row = (s) => (s ? Number(s) - 1 : null);
    const c0 = col(m[1]);
    const r0 = row(m[2]);
    const two = m[3] !== undefined || m[4] !== undefined;
    return { c0: c0 === null ? 0 : c0, r0: r0 === null ? 0 : r0, c1: two ? col(m[3]) : c0, r1: two ? row(m[4]) : r0 };
  }

  const DRAFT_TTL_MS = 30 * 60 * 1000;
  // Text compared as a person reads it: whitespace runs are one space,
  // zero-width characters dropped, ends trimmed.
  const normText = (v) => String(v === undefined || v === null ? "" : v).replace(/[\u200b-\u200d\u2060\ufeff]/g, "").replace(/\s+/g, " ").trim();

  // A private deep copy of plain data, so a write keeps no object its caller
  // can still change. Each own enumerable property is read once (a getter or
  // Proxy cannot answer differently later); arrays and plain objects from
  // any realm are copied, a Date becomes a new Date, an object with toJSON
  // (URL) its JSON value. Functions, symbols, cycles and other objects are
  // refused.
  function copyInput(value, name = "input", seen = []) {
    if (typeof value === "function" || typeof value === "symbol") throw new SiteError("invalid", `${name}: expected plain data, got a ${typeof value}`);
    if (value === null || typeof value !== "object") return value;
    const tag = Object.prototype.toString.call(value);
    if (tag === "[object Date]") return new Date(value.getTime());
    if (seen.includes(value)) throw new SiteError("invalid", `${name}: expected plain data, got a cycle`);
    if (Array.isArray(value)) {
      const out = [];
      const n = value.length;
      seen.push(value);
      for (let i = 0; i < n; i++) out.push(copyInput(value[i], `${name}[${i}]`, seen));
      seen.pop();
      return out;
    }
    const proto = Object.getPrototypeOf(value);
    if (tag !== "[object Object]" || (proto !== null && Object.getPrototypeOf(proto) !== null)) {
      if (typeof value.toJSON === "function") return copyInput(value.toJSON(), name, seen);
      throw new SiteError("invalid", `${name}: expected plain data, got ${tag}`);
    }
    const out = {};
    seen.push(value);
    for (const key of Object.keys(value)) out[key] = copyInput(value[key], `${name}.${key}`, seen);
    seen.pop();
    return out;
  }

  function deepFreeze(value) {
    if (value && typeof value === "object" && !Object.isFrozen(value)) {
      Object.freeze(value);
      for (const key of Object.keys(value)) deepFreeze(value[key]);
    }
    return value;
  }

  // JSON with object keys sorted, so two values compare by content.
  function canonicalJSON(value) {
    if (isArray(value)) {
      let out = "[";
      for (let i = 0; i < value.length; i++) out += (i ? "," : "") + canonicalJSON(value[i]);
      return out + "]";
    }
    if (value && typeof value === "object") {
      const keys = objectKeys(value).sort();
      let out = "{";
      for (let i = 0; i < keys.length; i++) out += (i ? "," : "") + stringify(keys[i]) + ":" + canonicalJSON(value[keys[i]]);
      return out + "}";
    }
    return stringify(value === undefined ? null : value);
  }

  // A read-back value as plain data, copied: strings, booleans, finite
  // numbers and null, in arrays and plain objects (of any realm: an
  // Object.prototype or no prototype) whose own properties are all
  // enumerable data properties. Each is read once through its descriptor,
  // so no getter, toJSON or toString runs and nothing answers differently
  // later; the copy has only those own values (nothing it inherits).
  // Anything else (a function, a symbol, a Date or other object, an
  // accessor, past 32 levels, so also a cycle) is not a reading: NOT_PLAIN.
  const NOT_PLAIN = Symbol("not plain data");
  const isPlainObject = (value) => {
    if (objectTag(value) !== "[object Object]") return false;
    const proto = getPrototypeOf(value);
    return proto === null || getPrototypeOf(proto) === null;
  };
  function plainReading(value, depth = 0) {
    if (value === null || typeof value === "string" || typeof value === "boolean") return value;
    if (typeof value === "number") return numberIsFinite(value) ? value : NOT_PLAIN;
    if (typeof value !== "object" || depth > 32) return NOT_PLAIN;
    const array = isArray(value);
    if (!array && !isPlainObject(value)) return NOT_PLAIN;
    const out = array ? [] : {};
    for (const key of ownNames(value)) {
      if (array && key === "length") continue;
      const d = ownDescriptor(value, key);
      if (!d || !("value" in d) || !d.enumerable) return NOT_PLAIN;
      const v = plainReading(d.value, depth + 1);
      if (v === NOT_PLAIN) return NOT_PLAIN;
      defineProperty(out, key, { value: v, enumerable: true, writable: true, configurable: true });
    }
    return out;
  }
  const shown = (v) => {
    const text = typeof v === "string" ? JSON.stringify(v) : canonicalJSON(v);
    return text.length > 160 ? text.slice(0, 159) + "…" : text;
  };
  // 64-bit FNV-1a of a string as 16 hex digits: a draft shows it for
  // content too long to show (a document's text), and its commit compares
  // the hash of what the site holds then.
  function hash(text) {
    let h = 0xcbf29ce484222325n;
    const s = String(text);
    for (let i = 0; i < s.length; i++) h = ((h ^ BigInt(s.charCodeAt(i))) * 0x100000001b3n) & 0xffffffffffffffffn;
    return h.toString(16).padStart(16, "0");
  }
  const INTENT_GROUPS = ["account", "target", "content"];
  const GROUP_WORDS = { account: "account it acts as", target: "object it acts on", content: "content it sends" };

  // The typed intent of a write: `account` (the principal that acts, by
  // stable ids), `target` (the object it acts on or the people it
  // reaches, by stable ids) and `content` (every other field). The
  // preview is the three groups merged, so the draft shows every bound
  // field and nothing else. `sent` names content fields the write sends
  // from the frozen intent itself (a post's text in an API body), which no
  // page holds to read back; account and target fields are always read
  // back. `canon` maps a field to the form both sides are compared in.
  function intentOf(site, action, spec) {
    const where = `sites.${site}.${action}`;
    const groupOf = {};
    const preview = {};
    for (const g of INTENT_GROUPS) {
      const fields = spec[g] === undefined && g !== "account" ? {} : spec[g];
      if (!fields || typeof fields !== "object" || Array.isArray(fields)) throw new SiteError("invalid", `${where}: the draft's ${g} is not an object (a site tool bug)`);
      for (const k of Object.keys(fields)) {
        if (k in groupOf) throw new SiteError("invalid", `${where}: the draft names ${k} twice (a site tool bug)`);
        groupOf[k] = g;
        preview[k] = fields[k];
      }
    }
    if (!Object.keys(spec.account).length) throw new SiteError("invalid", `${where}: the draft names no account (a site tool bug)`);
    const sent = new Set(spec.sent || []);
    for (const k of sent) if (groupOf[k] !== "content") throw new SiteError("invalid", `${where}: ${k} is not a content field; only content may be sent from the draft without reading it back (a site tool bug)`);
    if (typeof spec.commit !== "function") throw new SiteError("invalid", `${where}: the draft has no commit (a site tool bug)`);
    return { preview, groupOf, sent, canon: spec.canon || {} };
  }

  // Compares what the page holds right before the write with the draft:
  // every field not `sent` must be read back and equal. A difference fails
  // as <group>_mismatch, a field the page did not give as
  // <group>_unverified; account first, then target, then content.
  //
  // `observed` is read once, as plain data (plainReading): a bound field
  // whose value is not plain data (it would serialize or convert itself:
  // toJSON, toString, a getter) is unread, so <group>_unverified.
  // `groups` limits the check to some groups (the account alone, read
  // again as the last step before a click).
  function checkIntent(where, entry, read, groups = INTENT_GROUPS) {
    const { preview, groupOf, sent, canon } = entry.intent;
    const problems = { account: [], target: [], content: [] };
    const unknown = { account: [], target: [], content: [] };
    const observed = {};
    const unreadable = new Set();
    if (read && typeof read === "object" && isPlainObject(read)) {
      for (const k of ownNames(read)) {
        const d = ownDescriptor(read, k);
        const v = d && "value" in d && d.enumerable ? (d.value === undefined ? undefined : plainReading(d.value)) : NOT_PLAIN;
        if (v === NOT_PLAIN) unreadable.add(k);
        else if (v !== undefined) defineProperty(observed, k, { value: v, enumerable: true, writable: true, configurable: true });
      }
    }
    const has = (k) => ownDescriptor(observed, k) !== undefined;
    for (const k of objectKeys(preview)) {
      if (sent.has(k)) continue;
      const g = groupOf[k];
      if (!groups.includes(g)) continue;
      if (!has(k)) {
        unknown[g].push(k);
        continue;
      }
      let a;
      let b;
      try {
        const c = canon[k] || ((x) => x);
        a = canonicalJSON(c(observed[k]));
        b = canonicalJSON(c(preview[k]));
      } catch (e) {
        unknown[g].push(k);
        continue;
      }
      if (a !== b) problems[g].push(`${k} is ${shown(observed[k])}, not ${shown(preview[k])}`);
    }
    const drafted = (k) => ownDescriptor(preview, k) !== undefined;
    for (const k of unreadable) if (!drafted(k)) unknown.content.push(k);
    for (const k of objectKeys(observed)) if (!drafted(k)) problems.content.push(`it also holds ${k} ${shown(observed[k])}, which the draft does not show`);
    for (const g of INTENT_GROUPS) if (problems[g].length) throw new SiteError(`${g}_mismatch`, `${where}: the ${GROUP_WORDS[g]} differs from the draft (${problems[g].join("; ")}); nothing was sent. Make a new draft and show it to the user again`);
    for (const g of INTENT_GROUPS) if (unknown[g].length) throw new SiteError(`${g}_unverified`, `${where}: could not read ${unknown[g].join(", ")} back from the site right before the write, so the ${GROUP_WORDS[g]} is not verified; nothing was sent`);
    return objectKeys(preview).filter((k) => !sent.has(k));
  }

  // Drafts live in the REPL session that made them, so a draft can be
  // confirmed only by the session the user saw it in (use --session NAME).
  // A draft's record (status, expiry, intent) stays here; the agent gets
  // frozen views of it. The preview is a frozen JSON copy of the intent
  // whose canonical text is kept: confirming runs the draft's commit with
  // that same intent, after checking the text still matches.
  //
  // The commit protocol: commit(c) prepares the write (opens the page,
  // fills the composer) and then calls c.write(observe, act, options)
  // once. observe() reads every bound field back from the site; the loader
  // compares it with the intent (checkIntent) and calls act(press), the
  // write itself, only when all of it matches. A commit that returns
  // without calling c.write fails (commit_unverified).
  //
  // A write that is a click (Send, Post, Save, Replace all) presses
  // through press(), so the click lands on what the read-back verified:
  // { submit: locator } pins that element before observe(), and
  // press() presses exactly it (press(locator) pins one then, for a
  // control the act opens). press() waits until the element can take the
  // click and the pointer is on it, runs observe() and checkIntent again,
  // and sends the press bound to that element (the driver's press check):
  // a pinned element that left the document fails target_mismatch, a
  // change found by the second read-back fails as the first would, and
  // either way nothing is pressed. A commit with { submit } whose act
  // returns without press() fails (commit_unverified).
  //
  // press.next(locator) presses a second control the first press opened
  // (Calendar's invitation dialog Send after Save): the locator must match
  // exactly one element, which is pinned and pressed the same way, with
  // the same read-backs right before its click.
  //
  // { account: read } reads the account fields alone. press() runs it as
  // the last step before the click, after the second read-back, so another
  // session that switches the shared profile's account while the rest is
  // read back sends nothing (account_mismatch). What remains is the switch
  // between that read and the click reaching the page.
  //
  // A write that is typed keys or a paste (the Google editors' Sheets
  // paste and Delete, Slides notes, Docs append) has no control to pin:
  // press.input(fn) reads the account again ({ account } is required) and
  // runs fn, one batch of input, only when it is still the drafted one, so
  // another session that switches the shared profile's account after the
  // read-back changes nothing (account_mismatch, or account_unverified when
  // it cannot be read). Each batch that changes the site goes through it.
  // { inputs: "guarded" } makes that the commit's contract: an act that
  // returns having used neither press() nor press.input() fails
  // (commit_unverified).
  const PRESS_TIMEOUT_MS = 15000;
  async function pinElement(where, locator) {
    if (!locator || typeof locator.elementHandle !== "function") throw new SiteError("invalid", `${where}: the control to press is not a locator (a site tool bug)`);
    return locator.elementHandle({ timeout: PRESS_TIMEOUT_MS });
  }
  async function pressPinned(where, el, recheck) {
    const frame = el._pinnedFrame;
    const handle = el._handle;
    const changed = () => new SiteError("target_mismatch", `${where}: the control the read-back verified was replaced or removed before the click; nothing was sent. Make a new draft and show it to the user again`);
    // The pinned element only: no lookup finds another element in its place.
    const bound = Object.create(el);
    bound._resolveOne = async () => {
      if (!(await frame._agent("rect", handle).catch(() => null))) throw changed();
      return { frame, handle };
    };
    bound._resolveAll = async () => {
      const r = await bound._resolveOne();
      return { frame: r.frame, handles: [r.handle] };
    };
    await bound._pointer({ timeout: PRESS_TIMEOUT_MS }, `${where} (press)`, ["visible", "enabled", "stable"], async (target) => {
      if (target.frame !== frame || target.handle !== handle) throw changed();
      await recheck();
      await el._page._clickAt(target, {}, `${where} (press)`);
    });
  }

  function createDrafts(host, writesOf) {
    const drafts = new Map();
    let n = 0;
    const now = () => (host.now ? host.now() : Date.now());
    const rand = () => Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, "0");
    const view = (e) =>
      Object.freeze({
        id: e.id,
        site: e.site,
        action: e.action,
        status: e.status,
        summary: e.summary,
        category: e.category,
        preview: e.preview,
        checked: Object.freeze([...(e.checked || [])]),
        expiresAt: new Date(e.expiresAt).toISOString(),
        confirm: `await sites.${e.site}.${e.action}(${JSON.stringify(e.id)}, { confirm: true })`,
      });
    return {
      create(site, action, spec) {
        const where = `sites.${site}.${action}`;
        if (!writesOf(site).includes(action)) throw new SiteError("invalid", `${where} is not a declared write of sites.${site} (a site tool bug)`);
        const intent = intentOf(site, action, spec);
        let canonical;
        try {
          canonical = JSON.stringify(intent.preview);
        } catch (e) {
          throw new SiteError("invalid", `${where}: the draft preview is not JSON data (${(e && e.message) || e})`);
        }
        const preview = deepFreeze(JSON.parse(canonical));
        // Compare with the JSON form the user sees (a Date as its string).
        intent.preview = preview;
        const id = `draft-${++n}-${rand()}`;
        const entry = { id, site, action, status: "draft", summary: String(spec.summary), category: String(spec.category), preview, canonical, intent, expiresAt: now() + DRAFT_TTL_MS, commit: spec.commit, checked: null };
        drafts.set(id, entry);
        return view(entry);
      },
      async run(id, site, action) {
        const where = `sites.${site}.${action}`;
        const entry = drafts.get(id);
        if (!entry) throw new SiteError("draft_not_found", `${where}: no draft ${JSON.stringify(id)} in this REPL session. Drafts live in the session that made them; run both calls in one named session (cmux browser repl --session NAME).`);
        if (entry.site !== site || entry.action !== action) throw new SiteError("draft_mismatch", `${where}: draft ${id} is a sites.${entry.site}.${entry.action} draft`);
        if (entry.status !== "draft") throw new SiteError("draft_used", `${where}: draft ${id} is ${entry.status}; make a new draft`);
        if (now() > entry.expiresAt) {
          entry.status = "expired";
          throw new SiteError("draft_expired", `${where}: draft ${id} expired; make a new draft and show it to the user again`);
        }
        if (JSON.stringify(entry.preview) !== entry.canonical) {
          entry.status = "failed";
          throw new SiteError("draft_changed", `${where}: draft ${id} no longer matches its preview; nothing was sent. Make a new draft and show it to the user again`);
        }
        entry.status = "sending";
        let wrote = false;
        const c = Object.freeze({
          intent: entry.preview,
          async write(observe, act, options = {}) {
            if (wrote) throw new SiteError("commit_reused", `${where}: a draft writes once (a site tool bug)`);
            wrote = true;
            const submit = options && options.submit ? await pinElement(where, options.submit) : null;
            const readAccount = options && typeof options.account === "function" ? options.account : null;
            const guarded = !!(options && options.inputs === "guarded");
            if (guarded && !readAccount) throw new SiteError("invalid", `${where}: a guarded write needs the commit's { account } reader (a site tool bug)`);
            const check = async () => checkIntent(where, entry, await observe());
            const recheck = async () => {
              await check();
              if (readAccount) checkIntent(where, entry, await readAccount(), ["account"]);
            };
            entry.checked = await check();
            let pressed = false;
            const press = async (locator) => {
              if (pressed) throw new SiteError("commit_reused", `${where}: a write presses once (a site tool bug)`);
              pressed = true;
              const el = locator ? await pinElement(where, locator) : submit;
              if (!el) throw new SiteError("invalid", `${where}: press() needs the control to press (a site tool bug)`);
              await pressPinned(where, el, recheck);
            };
            let pressedNext = false;
            press.next = async (locator) => {
              if (!pressed) throw new SiteError("invalid", `${where}: press.next() presses a control the write's press() opened; call press() first (a site tool bug)`);
              if (pressedNext) throw new SiteError("commit_reused", `${where}: a write presses one follow-up control (a site tool bug)`);
              pressedNext = true;
              if (!locator || typeof locator.count !== "function") throw new SiteError("invalid", `${where}: press.next() needs the control to press (a site tool bug)`);
              const n = await locator.count();
              if (n !== 1) throw new SiteError("target_unverified", `${where}: expected one control to press after the first, found ${n}; nothing more was pressed`);
              await pressPinned(where, await pinElement(where, locator), recheck);
            };
            let inputs = 0;
            press.input = async (fn) => {
              if (!readAccount) throw new SiteError("invalid", `${where}: press.input() needs the commit's { account } reader (a site tool bug)`);
              if (typeof fn !== "function") throw new SiteError("invalid", `${where}: press.input() needs the input to run (a site tool bug)`);
              checkIntent(where, entry, await readAccount(), ["account"]);
              inputs++;
              return fn();
            };
            const result = await act(press);
            if (guarded && !pressed && !inputs) throw new SiteError("commit_unverified", `${where}: the tool wrote without press() or press.input(), so the account was not read again before its input (a site tool bug); treat the result as unverified`);
            if (submit && !pressed) throw new SiteError("commit_unverified", `${where}: the tool wrote without pressing the control its read-back verified (a site tool bug); treat the result as unverified`);
            return result;
          },
        });
        try {
          const result = await entry.commit(c);
          if (!wrote) throw new SiteError("commit_unverified", `${where}: the tool returned without reading the draft back before its write (a site tool bug); treat the result as unverified`);
          entry.status = "sent";
          return result;
        } catch (e) {
          // A failed send may have reached the site; never retry it blindly.
          entry.status = "failed";
          throw e;
        }
      },
      list: () => [...drafts.values()].map(view),
      get: (id) => (drafts.has(id) ? view(drafts.get(id)) : null),
      discard(id) {
        const entry = drafts.get(id);
        if (entry && entry.status === "draft") entry.status = "discarded";
        return !!entry;
      },
    };
  }

  function createSites(ctx) {
    const { session, host, fs, path } = ctx;
    const drafts = createDrafts(host, (site) => {
      const r = registry.find((x) => x.name === site);
      return r ? r.writes : [];
    });
    let files = 0;

    const tool = {
      SiteError,
      shared,
      ELEMENT_MARKDOWN,
      pageFunction,
      embeddedJSON,
      decodeEntities,
      parseCSV,
      parseA1Range,
      hash,
      URL: ctx.URL,
      Buffer: ctx.Buffer,
      fs,
      path,
      host,
      session,
      fetch: ctx.fetch,
      // fetchFrom(page, origin) is a fetch with that tab's cookies and that
      // origin's same-origin rule, whichever tab is current.
      fetchFrom: ctx.fetchFrom,
      currentPage: ctx.currentPage,
      snapshot: ctx.snapshot,
      sleep: (ms) => session.sleep(ms),
      now: () => session.now(),
      fail(code, message) {
        throw new SiteError(code, message);
      },
      // A file path for tool output: options.path, else the session's temp directory.
      outputPath(options, ext, base = "site") {
        if (options && options.path) return path.resolve(String(options.path));
        const dir = path.join(host.tmpdir, "cmux-browser-repl", String(host.sessionId || "session").replace(/[^\w.-]/g, "_"));
        fs.mkdirSync(dir, { recursive: true });
        const safe = String(base).replace(/[^\w.-]+/g, "_").slice(0, 80) || "site";
        return path.join(dir, `${safe}-${++files}${ext}`);
      },
      outputDir(options, base) {
        const dir = options && options.dir ? path.resolve(String(options.dir)) : path.join(host.tmpdir, "cmux-browser-repl", String(host.sessionId || "session").replace(/[^\w.-]/g, "_"), `${base}-${++files}`);
        fs.mkdirSync(dir, { recursive: true });
        return dir;
      },
      // GET through the signed-in session (cookie-bearing REPL fetch);
      // throws on HTTP errors with the tool's name.
      async get(name, url, init = {}) {
        const r = await ctx.fetch(url, init);
        if (!r.ok) throw new SiteError(r.status === 401 || r.status === 403 ? "not_signed_in" : "http", `${name}: HTTP ${r.status} for ${url}`);
        return r;
      },
      // Runs fn(page) in a background tab loaded at url, then closes the tab.
      // The current tab does not change.
      async withTab(url, fn, options = {}) {
        const page = await session.newPage(undefined, { background: true });
        try {
          await page.goto(url, { waitUntil: options.waitUntil || "load", timeout: options.timeout || 45000 });
          return await fn(page);
        } finally {
          await page.close().catch(() => {});
        }
      },
      // Runs page function fn(arg) in the world of a background tab at
      // origin + path (default /robots.txt, a same-origin document with no
      // scripts): same-origin fetches there send the site's cookies, and
      // whatever the function reads from the page stays there unless it
      // returns it. Functions must return only non-secret data.
      async inOrigin(origin, fn, arg, options = {}) {
        return tool.withOrigin(origin, (run) => run(fn, arg), options);
      },
      // Runs page function fn(arg) in the agent's isolated world of
      // `page`'s main frame (the world locators read in) and returns its
      // result. A commit's observe() reads the site with this, never with
      // page.evaluate: a page-world result is whatever the page makes of it
      // (its own JSON.stringify, toJSON, getters, patched built-ins), while
      // the agent's world has its own built-ins and the result crosses as
      // that world's JSON. The function sees the document and its cookies
      // (same origin), not the page's script globals.
      async readBack(page, fn, arg) {
        return page._mainFrame._call("agent", ns.core.functionSource(fn), [arg], undefined, "the read-back");
      },
      // Like inOrigin for several calls on one tab: body(run) where
      // run(fn, arg) evaluates in the page. A redirect can leave the tab on
      // another origin, whose page would then receive the call with the
      // profile's cookies: run() fails (origin_changed) unless the tab's
      // URL is on `origin`, and the evaluation itself first checks the
      // document's own location.origin, so no call runs in a document of
      // another origin, also one that replaced the page after the check.
      // { world: "agent" } runs the calls in the agent's isolated world
      // (readBack): a commit's observe() reads through that, since a
      // site's service worker can serve the path a page with scripts.
      async withOrigin(origin, body, options = {}) {
        const base = String(origin).replace(/\/$/, "");
        let want;
        try {
          want = new ctx.URL(base).origin;
        } catch (e) {
          want = null;
        }
        if (!want || !/^https?:\/\//.test(want)) throw new SiteError("invalid", `sites: expected an http(s) origin, got ${JSON.stringify(origin)}`);
        const changed = (where) => new SiteError("origin_changed", `sites: ${base}${options.path || "/robots.txt"} led to ${where}, not a page on ${want} (a redirect); nothing ran there`);
        return tool.withTab(base + (options.path || "/robots.txt"), (page) =>
          body(async (fn, arg) => {
            let at = null;
            try {
              at = new ctx.URL(page.url()).origin;
            } catch (e) {}
            if (at !== want) throw changed(page.url());
            // eslint-disable-next-line no-new-func
            const guarded = new Function("__cmux", `if (location.origin !== __cmux.origin) return { __cmuxWrongOrigin: String(location.origin) };\nreturn (${String(fn)})(__cmux.arg);`);
            const r = options.world === "agent" ? await tool.readBack(page, guarded, { origin: want, arg }) : await page.evaluate(guarded, { origin: want, arg });
            if (r && typeof r === "object" && typeof r.__cmuxWrongOrigin === "string" && Object.keys(r).length === 1) throw changed(r.__cmuxWrongOrigin);
            return r;
          }),
        options);
      },
      // Waits in `page` until fn(arg) returns a truthy value; returns it.
      // With { signIn: [patterns], name }, a tab that reaches a sign-in page
      // at any point (sites also redirect from script) fails as not_signed_in.
      // { world: "agent" } evaluates in the agent's world (readBack), as a
      // commit's observe() must.
      async waitIn(page, fn, arg, { timeout = 20000, what = "the page", signIn, name = "sites", world = "page" } = {}) {
        const deadline = session.now() + timeout;
        for (;;) {
          if (signIn) tool.assertSignedIn(name, page, signIn);
          let v = null;
          try {
            v = world === "agent" ? await tool.readBack(page, fn, arg) : await page.evaluate(fn, arg);
          } catch (e) {
            // A navigation replaced the document; try again on the new one.
            if (!/stale|navigat|context|detached|destroyed/i.test(String(e && e.message))) throw e;
          }
          if (v) return v;
          if (session.now() >= deadline) {
            if (signIn) tool.assertSignedIn(name, page, signIn);
            throw new SiteError("timeout", `${name}: timed out after ${timeout}ms waiting for ${what} (${page.url()})`);
          }
          await session.sleep(150);
        }
      },
      // Throws not_signed_in when a tab landed on a sign-in page.
      assertSignedIn(name, page, patterns) {
        const url = page.url();
        if (patterns.some((p) => p.test(url))) throw new SiteError("not_signed_in", `${name}: the cmux browser is not signed in (landed on ${url.split("?")[0]}). Open the site with tabs.open(url) and ask the user to sign in, or use sites.browserAuth.request().`);
      },
      // A private deep copy of plain data (see copyInput).
      copyInput,
      // A write that reaches other people: the first call returns a draft; a
      // second call with the draft id and { confirm: true } performs it.
      // make() receives a private copy of input, so what it captures cannot
      // be changed by the caller afterwards. make() (may be async) resolves
      // the concrete account and target (ids, emails) and returns { category,
      // summary, account, target, content, sent?, canon?, commit(c) }: the
      // typed intent the draft shows, and the commit that reads it back
      // right before the write (createDrafts). State another session
      // changes between the preview and the confirmation fails the write.
      write(site, action, input, options, make) {
        const isDraftId = typeof input === "string" && /^draft-\d+-[0-9a-f]+$/.test(input);
        if (isDraftId) {
          if (!options || options.confirm !== true) throw new SiteError("confirm_required", `sites.${site}.${action}: pass { confirm: true } to perform draft ${input}, after the user has seen its preview`);
          return drafts.run(input, site, action);
        }
        if (options && options.confirm) throw new SiteError("draft_required", `sites.${site}.${action}: { confirm: true } takes a draft id. Call sites.${site}.${action}(input) first, show the returned draft to the user, then confirm it.`);
        const spec = make(copyInput(input, `sites.${site}.${action}`));
        const create = (s) => drafts.create(site, action, s);
        return spec && typeof spec.then === "function" ? spec.then(create) : create(spec);
      },
      // The whole text the composer at `locator` holds, for a commit's
      // observe(): read in the agent's isolated world, hidden text
      // included, whitespace collapsed and zero-width characters dropped
      // (normText), so a composer that keeps the draft's start and holds
      // more differs. `exclude`: a selector for the site's own additions
      // that are not the draft (Gmail's signature and quoted text).
      async composerText(locator, { exclude } = {}) {
        const text = await locator._read("composerText", exclude || null, {}, "composer text");
        return typeof text === "string" ? normText(text) : undefined;
      },
      normText,
    };

    const sites = {};
    const failed = {};
    for (const { name, factory } of registry) {
      try {
        sites[name] = factory(tool);
      } catch (e) {
        failed[name] = String((e && e.message) || e);
      }
    }
    Object.defineProperties(sites, {
      drafts: {
        value: { list: () => drafts.list(), get: (id) => drafts.get(id), discard: (id) => drafts.discard(id) },
        enumerable: false,
      },
      // One line per tool; sites.help(name) for its methods.
      list: {
        value: () => registry.map((r) => ({ name: r.name, summary: r.summary, writes: [...r.writes], ...(failed[r.name] ? { error: failed[r.name] } : {}) })),
        enumerable: false,
      },
      help: {
        value: (name) => {
          const t = name ? sites[name] : null;
          if (name && !t) throw new SiteError("invalid", `sites.help: no tool ${JSON.stringify(name)}; see sites.list()`);
          if (t) return Object.keys(t).filter((k) => typeof t[k] === "function").map((k) => `sites.${name}.${k}`).join("\n");
          return registry.map((r) => `sites.${r.name}: ${r.summary}`).join("\n");
        },
        enumerable: false,
      },
    });
    return sites;
  }

  ns.sites = { register, createSites, shared, SiteError, copyInput, hash, embeddedJSON, decodeEntities, parseCSV, parseA1Range, pageFunction, ELEMENT_MARKDOWN };
})(typeof globalThis !== "undefined" ? globalThis : this);
