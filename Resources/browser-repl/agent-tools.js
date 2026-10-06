// Reference C parity for the cmux browser REPL
// (docs/browser-repl/reference-c-parity.md): what reference C's tools,
// browser profile and agent offer that a REPL-driving agent can use, in this
// REPL's Playwright-shaped API and without a model inside cmux.
//
// Globals: secret(name), secrets, search(query, options), tools.
// session: allowedDomains, prohibitedDomains, blockIPAddresses,
//   blockedNavigations, storageState, setStorageState, downloads, record.
// Page: markdown, extract, searchText, scrollToText, scroll, scrollInfo,
//   dropdownOptions, highlight, hideHighlight; locator.highlight.
//
// The runtime calls the hooks below through session.agentTools
// (runtime-core.js Session.call, its event router, Page._afterAction and
// Page._inputText; repl-host.js output and errors; api.js fetch).
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  const core = ns.core;
  const { Buffer } = core;
  const AGENT = 'globalThis[Symbol.for("cmux.browserRepl.agent")]';

  // ---------------------------------------------------------------------------
  // Domain patterns, reference C's syntax (utils.match_url_with_domain_pattern
  // and the security watchdog): "example.com" (and www.example.com),
  // "*.example.com" (subdomains and the bare domain), "http*://example.com",
  // "https://example.com", "*". A port in the pattern must match (reference C
  // drops it). Multiple wildcards, wildcard TLDs and embedded wildcards are
  // refused when set, where reference C logs and ignores them.

  // Host names as the policy compares them: lower case, no trailing dot,
  // internationalized labels in Punycode, as the native session does
  // (BrowserReplHostName).
  function punycode(input) {
    const cps = [...input].map((c) => c.codePointAt(0));
    let out = cps.filter((c) => c < 0x80).map((c) => String.fromCharCode(c)).join("");
    const basic = out.length;
    let handled = basic;
    if (basic) out += "-";
    let n = 128;
    let delta = 0;
    let bias = 72;
    const digit = (d) => String.fromCharCode(d < 26 ? d + 97 : d + 22);
    const adapt = (d, count, first) => {
      d = first ? Math.floor(d / 700) : d >> 1;
      d += Math.floor(d / count);
      let k = 0;
      while (d > 455) {
        d = Math.floor(d / 35);
        k += 36;
      }
      return k + Math.floor((36 * d) / (d + 38));
    };
    while (handled < cps.length) {
      const m = Math.min(...cps.filter((c) => c >= n));
      delta += (m - n) * (handled + 1);
      n = m;
      for (const c of cps) {
        if (c < n) delta++;
        if (c === n) {
          let q = delta;
          for (let k = 36; ; k += 36) {
            const t = k <= bias ? 1 : k >= bias + 26 ? 26 : k - bias;
            if (q < t) break;
            out += digit(t + ((q - t) % (36 - t)));
            q = Math.floor((q - t) / (36 - t));
          }
          out += digit(q);
          bias = adapt(delta, handled + 1, handled === basic);
          delta = 0;
          handled++;
        }
      }
      delta++;
      n++;
    }
    return out;
  }
  function normalizeHost(raw) {
    let host = String(raw || "").trim();
    if (host.includes(":") && !host.startsWith("[")) host = `[${host}]`;
    if (host.startsWith("[")) return host.toLowerCase();
    host = host.replace(/\.+$/, "");
    return host
      .split(".")
      .map((label) => {
        const l = label.normalize("NFC").toLowerCase();
        return /[^\x00-\x7f]/.test(l) ? "xn--" + punycode(l) : l;
      })
      .join(".");
  }

  // `isPublicSuffix(name)` (the session's Public Suffix List, through
  // `policy("publicSuffix")`) refuses a wildcard over a public suffix such
  // as *.com or *.co.uk, which would name every site under it.
  function parsePattern(raw, title, isPublicSuffix) {
    if (typeof raw !== "string" || !raw.trim()) throw new Error(`${title}: expected domain patterns as non-empty strings, got ${JSON.stringify(raw)}`);
    let p = raw.trim().toLowerCase();
    let scheme = null;
    const m = /^([a-z*][a-z0-9+.*-]*):\/\/(.*)$/.exec(p);
    if (m) {
      scheme = m[1];
      p = m[2];
    }
    p = p.replace(/\/.*$/, "");
    let port = null;
    const pm = /^(.*):(\d+|\*)$/.exec(p);
    if (pm && !p.startsWith("[")) {
      p = pm[1];
      port = pm[2] === "*" ? null : pm[2];
    }
    const host = p;
    if (host !== "*") {
      if ((host.match(/\*/g) || []).length > 1) throw new Error(`${title}: ${JSON.stringify(raw)}: only one wildcard is allowed`);
      if (host.endsWith(".*")) throw new Error(`${title}: ${JSON.stringify(raw)}: wildcard top-level domains are not allowed`);
      if (host.includes("*") && !host.startsWith("*.")) throw new Error(`${title}: ${JSON.stringify(raw)}: use *.example.com; other wildcards are not allowed`);
      if (!host || /[\s/]/.test(host)) throw new Error(`${title}: ${JSON.stringify(raw)}: expected a domain`);
    }
    const normalized = host === "*" ? host : host.startsWith("*.") ? "*." + normalizeHost(host.slice(2)) : normalizeHost(host);
    if (!normalized || normalized === "*.") throw new Error(`${title}: ${JSON.stringify(raw)}: expected a domain`);
    if (normalized.startsWith("*.") && isPublicSuffix && isPublicSuffix(normalized.slice(2))) {
      const base = normalized.slice(2);
      throw new Error(`${title}: ${JSON.stringify(raw)}: ${base} is a public suffix, so *.${base} would cover every site under it; name a site, such as *.example.${base}`);
    }
    return { raw, scheme, host: normalized, port };
  }

  // WebKit content-blocker rules for a domain policy. Content-blocker regular
  // expressions have no alternation, so each pattern becomes its own rule.
  // Documents in the main frame are left to the navigation checks, which
  // report the block; iframes and every subresource are blocked here.
  const SUBRESOURCES = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping", "fetch", "websocket", "other"];
  const cbEscape = (s) => s.replace(/[.+?^${}()|[\]\\*]/g, "\\$&");
  function patternFilters(p) {
    // Without a scheme a pattern covers http(s) and its WebSockets.
    const schemes = p.scheme ? [p.scheme.split("").map((c) => (c === "*" ? "[a-z0-9+.-]*" : cbEscape(c))).join("")] : ["https?", "wss?"];
    return schemes.flatMap((scheme) => schemeFilters(p, scheme));
  }
  function schemeFilters(p, scheme) {
    let host;
    if (p.host === "*") host = "[^/@:]+";
    else if (p.host.startsWith("*.")) host = "([^/@:]*\\.)?" + cbEscape(p.host.slice(2)) + "\\.?";
    else host = cbEscape(p.host) + "\\.?";
    const head = "^" + scheme + "://([^/@]*@)?" + host;
    if (p.port === null) return [head + "(:[0-9]+)?/"];
    const out = [head + ":" + p.port + "/"];
    // A default port is not written in the URL.
    if ((p.port === "443" && (!p.scheme || /^https/.test(p.scheme) || p.scheme === "*")) || (p.port === "80" && (!p.scheme || /^http/.test(p.scheme) || p.scheme === "*"))) out.push(head + "/");
    return out;
  }
  function policyContentRules(policy) {
    const rules = [];
    const triggers = (filter) => [
      { "url-filter": filter, "resource-type": SUBRESOURCES },
      { "url-filter": filter, "resource-type": ["document"], "load-context": ["child-frame"] },
    ];
    const add = (filter, type) => {
      for (const trigger of triggers(filter)) rules.push({ trigger, action: { type } });
    };
    if (policy.allowed) {
      add(".*", "block");
      for (const p of policy.allowed) for (const f of patternFilters(p)) add(f, "ignore-previous-rules");
      for (const scheme of ["data", "blob", "about"]) add("^" + scheme + ":", "ignore-previous-rules");
    }
    for (const p of policy.prohibited) for (const f of patternFilters(p)) add(f, "block");
    if (policy.blockIPs) {
      add("^[a-z][a-z0-9+.-]*://([^/@]*@)?[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\.?[:/]", "block");
      add("^[a-z][a-z0-9+.-]*://([^/@]*@)?\\[", "block");
    }
    return rules;
  }

  const globRe = (glob) => new RegExp("^" + glob.replace(/[.+^${}()|[\]\\?]/g, "\\$&").replace(/\*/g, ".*") + "$");
  const LOOPBACK = /^(localhost|127(?:\.\d{1,3}){3}|\[::1\])$/;

  // `secure`: a pattern without a scheme matches https only (and http on a
  // loopback host), as reference C's secret matching does; otherwise it
  // matches http and https, as its allowed_domains check does.
  function urlMatches(url, pattern, secure) {
    let u;
    try {
      u = new core.URL(url);
    } catch {
      return false;
    }
    const scheme = String(u.protocol || "").replace(/:$/, "").toLowerCase();
    const host = normalizeHost(u.hostname || "");
    if (!host) return false;
    if (pattern.scheme) {
      if (!globRe(pattern.scheme).test(scheme)) return false;
    } else if (secure) {
      if (!(scheme === "https" || (scheme === "http" && LOOPBACK.test(host)))) return false;
    } else if (scheme !== "http" && scheme !== "https") return false;
    if (pattern.port !== null) {
      const port = u.port || (scheme === "https" ? "443" : scheme === "http" ? "80" : "");
      if (port !== pattern.port) return false;
    }
    const h = pattern.host;
    if (h === "*") return true;
    if (h.startsWith("*.")) {
      const base = h.slice(2);
      return host === base || host.endsWith("." + base);
    }
    if (host === h) return true;
    // A root domain also covers www (the watchdog's www variant).
    return h.split(".").length === 2 && host === "www." + h;
  }

  // IPv4 in any form the URL parser accepts (it normalizes decimal, hex and
  // octal to dotted form) and bracketed IPv6.
  // An IP host: bracketed IPv6, or a name whose last label is a number,
  // which URL parsers read as IPv4 (127.1, 0x7f.0.0.1).
  const isIPHost = (host) => /^\[[0-9a-f:.]+\]$/i.test(host) || /(^|\.)(\d+|0x[0-9a-f]*)$/i.test(normalizeHost(host));

  // ---------------------------------------------------------------------------
  // TOTP (RFC 6238) for secrets registered with { totp: true }: reference C's
  // `bu_2fa_code` secrets.

  function base32Decode(s) {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    const clean = String(s).toUpperCase().replace(/[\s=-]/g, "");
    const out = [];
    let bits = 0;
    let value = 0;
    for (const c of clean) {
      const i = alphabet.indexOf(c);
      if (i < 0) throw new Error("secrets: a TOTP secret must be base32");
      value = (value << 5) | i;
      bits += 5;
      if (bits >= 8) {
        out.push((value >>> (bits - 8)) & 255);
        bits -= 8;
      }
    }
    return new Uint8Array(out);
  }

  function sha1(bytes) {
    const ml = bytes.length;
    const withPad = new Uint8Array((((ml + 9 + 63) >> 6) << 6));
    withPad.set(bytes);
    withPad[ml] = 0x80;
    const dv = new DataView(withPad.buffer);
    dv.setUint32(withPad.length - 4, (ml * 8) >>> 0);
    dv.setUint32(withPad.length - 8, Math.floor((ml * 8) / 2 ** 32));
    let [a0, b0, c0, d0, e0] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];
    const w = new Uint32Array(80);
    const rotl = (x, n) => (x << n) | (x >>> (32 - n));
    for (let off = 0; off < withPad.length; off += 64) {
      for (let i = 0; i < 16; i++) w[i] = dv.getUint32(off + i * 4);
      for (let i = 16; i < 80; i++) w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      let [a, b, c, d, e] = [a0, b0, c0, d0, e0];
      for (let i = 0; i < 80; i++) {
        const f = i < 20 ? (b & c) | (~b & d) : i < 40 ? b ^ c ^ d : i < 60 ? (b & c) | (b & d) | (c & d) : b ^ c ^ d;
        const k = i < 20 ? 0x5a827999 : i < 40 ? 0x6ed9eba1 : i < 60 ? 0x8f1bbcdc : 0xca62c1d6;
        const t = (rotl(a, 5) + f + e + k + w[i]) >>> 0;
        e = d;
        d = c;
        c = rotl(b, 30) >>> 0;
        b = a;
        a = t;
      }
      a0 = (a0 + a) >>> 0;
      b0 = (b0 + b) >>> 0;
      c0 = (c0 + c) >>> 0;
      d0 = (d0 + d) >>> 0;
      e0 = (e0 + e) >>> 0;
    }
    const out = new Uint8Array(20);
    const odv = new DataView(out.buffer);
    [a0, b0, c0, d0, e0].forEach((v, i) => odv.setUint32(i * 4, v));
    return out;
  }

  function hmacSha1(key, msg) {
    if (key.length > 64) key = sha1(key);
    const k = new Uint8Array(64);
    k.set(key);
    const inner = new Uint8Array(64 + msg.length);
    const outer = new Uint8Array(64 + 20);
    for (let i = 0; i < 64; i++) {
      inner[i] = k[i] ^ 0x36;
      outer[i] = k[i] ^ 0x5c;
    }
    inner.set(msg, 64);
    outer.set(sha1(inner), 64);
    return sha1(outer);
  }

  function totp(secretBase32, timeMs, { digits = 6, period = 30 } = {}) {
    const counter = Math.floor(timeMs / 1000 / period);
    const msg = new Uint8Array(8);
    const dv = new DataView(msg.buffer);
    dv.setUint32(0, Math.floor(counter / 2 ** 32));
    dv.setUint32(4, counter >>> 0);
    const h = hmacSha1(base32Decode(secretBase32), msg);
    const o = h[19] & 15;
    const code = (((h[o] & 127) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3]) % 10 ** digits;
    return String(code).padStart(digits, "0");
  }

  // ---------------------------------------------------------------------------
  // Animated PNG from same-size PNG frames, by moving their IDAT data into
  // APNG frame chunks (no decoding).

  const CRC_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c >>> 0;
    }
    return t;
  })();
  function crc32(bytes) {
    let c = 0xffffffff;
    for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 255] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  }
  function pngChunks(png) {
    const dv = new DataView(png.buffer, png.byteOffset, png.byteLength);
    const out = [];
    for (let off = 8; off + 8 <= png.length;) {
      const len = dv.getUint32(off);
      const type = String.fromCharCode(png[off + 4], png[off + 5], png[off + 6], png[off + 7]);
      out.push({ type, data: png.subarray(off + 8, off + 8 + len) });
      off += 12 + len;
    }
    return out;
  }
  function chunk(type, data) {
    const out = new Uint8Array(12 + data.length);
    const dv = new DataView(out.buffer);
    dv.setUint32(0, data.length);
    for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
    out.set(data, 8);
    dv.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
    return out;
  }
  function u32s(...values) {
    const b = new Uint8Array(values.length * 4);
    const dv = new DataView(b.buffer);
    values.forEach((v, i) => dv.setUint32(i * 4, v));
    return b;
  }
  // Frames whose header differs from the first (another size) are skipped.
  function buildApng(frames, delayMs = 800) {
    const parsed = frames.map((f) => pngChunks(f instanceof Uint8Array ? f : new Uint8Array(f)));
    const ihdr = parsed[0].find((c) => c.type === "IHDR").data;
    const same = parsed.filter((cs) => {
      const h = cs.find((c) => c.type === "IHDR");
      return h && h.data.length === ihdr.length && h.data.every((b, i) => b === ihdr[i]);
    });
    const width = new DataView(ihdr.buffer, ihdr.byteOffset).getUint32(0);
    const height = new DataView(ihdr.buffer, ihdr.byteOffset).getUint32(4);
    const parts = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("acTL", u32s(same.length, 0))];
    let seq = 0;
    same.forEach((cs, i) => {
      const fctl = new Uint8Array(26);
      fctl.set(u32s(seq++, width, height, 0, 0));
      new DataView(fctl.buffer).setUint16(20, delayMs);
      new DataView(fctl.buffer).setUint16(22, 1000);
      parts.push(chunk("fcTL", fctl));
      for (const c of cs) {
        if (c.type !== "IDAT") continue;
        if (i === 0) parts.push(chunk("IDAT", c.data));
        else {
          const d = new Uint8Array(4 + c.data.length);
          d.set(u32s(seq++));
          d.set(c.data, 4);
          parts.push(chunk("fdAT", d));
        }
      }
    });
    parts.push(chunk("IEND", new Uint8Array(0)));
    return { bytes: Buffer.concat(parts.map((p) => Buffer.from(p))), frames: same.length, skipped: frames.length - same.length };
  }

  // ---------------------------------------------------------------------------
  // Page functions (agent world: closed shadow roots are open to it).

  // The frame as Markdown blocks. Iframes become placeholders
  // "\u0000F<mark>:<i>\u0000" with their handles, so the host stitches each
  // frame's Markdown in place. <mark> is random per call and made in this
  // world, which page script cannot read, so page text cannot spell a
  // placeholder (the host also turns the page's own NULs into U+FFFD).
  // The read stops at the page-read budget the host passes on (A.budget:
  // nodes, characters, time) and at `maxFrames` iframes; `report` and
  // `framesCut` say where it stopped.
  function markdownOfFrame(opts) {
    const A = globalThis[Symbol.for("cmux.browserRepl.agent")];
    const B = A.budget({ maxNodes: opts.maxNodes, maxSize: opts.maxSize });
    const maxFrames = opts.maxFrames >= 0 ? opts.maxFrames : 100;
    let framesCut = false;
    // The walk recurses per element (blocks, inline runs, display:contents
    // boxes), and script can nest elements deeper than the stack: past
    // MAX_NEST levels, as the snapshot walk, a subtree is left out and
    // `nestCut` says so.
    const MAX_NEST = 1000;
    let nest = 0;
    let nestCut = false;
    const deeper = (read, empty) => {
      if (nest >= MAX_NEST) {
        nestCut = true;
        return empty;
      }
      nest++;
      try {
        return read();
      } finally {
        nest--;
      }
    };
    const frames = [];
    // Page text and attribute values, charged to the budget.
    const text = (v) => (B.truncated || !v ? "" : B.fit(String(v)));
    // The nodes of a child list, each charged; none once the budget is spent.
    const take = (list) => {
      const out = [];
      for (let i = 0; i < list.length && B.spend(1); i++) out.push(list[i]);
      return out;
    };
    const append = (out, list) => {
      for (const x of list) out.push(x);
      return out;
    };
    const words = new Uint32Array(4);
    if (globalThis.crypto && crypto.getRandomValues) crypto.getRandomValues(words);
    else for (let i = 0; i < words.length; i++) words[i] = Math.floor(Math.random() * 0x100000000);
    const mark = [...words].map((w) => w.toString(36)).join("");
    const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "META", "LINK", "TITLE", "SVG", "CANVAS", "VIDEO", "AUDIO", "OBJECT", "EMBED", "MAP", "DIALOG"]);
    const OUTSIDE_MAIN = new Set(["navigation", "banner", "contentinfo", "complementary", "search"]);
    const styles = new Map();
    const style = (el) => {
      let cs = styles.get(el);
      if (!cs) styles.set(el, (cs = getComputedStyle(el)));
      return cs;
    };
    const tag = (el) => (el.tagName || "").toUpperCase();
    const landmark = (el) => {
      const role = el.getAttribute("role");
      if (role) return role;
      const t = tag(el);
      if (t === "NAV") return "navigation";
      if (t === "ASIDE") return "complementary";
      if ((t === "HEADER" || t === "FOOTER") && !el.closest("article, main, section, [role=main], [role=article]")) return t === "HEADER" ? "banner" : "contentinfo";
      return null;
    };
    const skipped = (el, ctx) => {
      if (SKIP.has(tag(el))) return true;
      if (tag(el) === "DIALOG" && el.open) return false;
      const cs = style(el);
      if (cs.display === "none" || cs.contentVisibility === "hidden") return true;
      if (ctx.main && OUTSIDE_MAIN.has(landmark(el))) return true;
      return false;
    };
    // Children in the flat tree: a shadow root's, a slot's assigned nodes,
    // and the children of display:contents boxes in their place.
    const kids = (el) => {
      const out = [];
      for (const c of ownKids(el)) {
        if (c.nodeType === 1 && !SKIP.has(tag(c)) && style(c).display === "contents") append(out, deeper(() => kids(c), []));
        else out.push(c);
      }
      return out;
    };
    const ownKids = (el) => {
      if (el.shadowRoot) return take(el.shadowRoot.childNodes);
      if (tag(el) === "SLOT") {
        const assigned = el.assignedNodes({ flatten: true });
        return take(assigned.length ? assigned : el.childNodes);
      }
      if (tag(el) === "DETAILS" && !el.open) return take(el.children).filter((c) => tag(c) === "SUMMARY");
      return take(el.childNodes);
    };
    // A <pre>'s text, read node by node within the budget.
    const textOf = (el) => {
      let out = "";
      const walker = document.createTreeWalker(el, 4 /* NodeFilter.SHOW_TEXT */);
      for (let n = walker.nextNode(); n && B.spend(1); n = walker.nextNode()) out += text(n.data);
      return out;
    };
    const sub = (el, ctx) => {
      const cs = style(el);
      return cs.visibility === "hidden" || cs.visibility === "collapse" ? { ...ctx, hidden: true } : cs.visibility === "visible" ? { ...ctx, hidden: false } : ctx;
    };
    const isInline = (el) => {
      const t = tag(el);
      if (/^(H[1-6]|P|PRE|UL|OL|TABLE|BLOCKQUOTE|HR|IFRAME|FRAME|LI|DL|DT|DD|FIGURE|SECTION|ARTICLE|DETAILS|SUMMARY)$/.test(t)) return false;
      return style(el).display.startsWith("inline");
    };
    const collapse = (s) => s.replace(/[\s ]+/g, " ");
    const esc = (s) => s.replace(/([\\`*_[\]])/g, "\\$1");
    // A URL longer than the budget has left (with the base it resolves
    // against) is not resolved: text() charges and cuts it as written.
    const absURL = (v) => {
      if (v.length + document.baseURI.length > B.sizeLeft) return v;
      try {
        return new URL(v, document.baseURI).href;
      } catch (e) {
        return v;
      }
    };
    const fieldValue = (el) => {
      const t = tag(el);
      if (t === "SELECT") return take(el.selectedOptions).map((o) => text(o.label || o.text)).join(", ");
      if (t === "TEXTAREA") return text(el.value);
      if (t === "INPUT") {
        const type = (el.type || "text").toLowerCase();
        if (type === "password" || type === "hidden" || type === "file") return "";
        if (type === "checkbox" || type === "radio") return el.checked ? "[x]" : "[ ]";
        return text(el.value);
      }
      return "";
    };

    function inline(node, ctx) {
      if (node.nodeType === 3) return ctx.hidden ? "" : collapse(text(node.data));
      if (node.nodeType !== 1 || skipped(node, ctx)) return "";
      return deeper(() => inlineElement(node, ctx), "");
    }
    function inlineElement(node, ctx) {
      ctx = sub(node, ctx);
      const t = tag(node);
      if (t === "BR") return "\n";
      if (t === "IFRAME" || t === "FRAME") return "";
      if (t === "IMG") {
        if (ctx.hidden) return "";
        const alt = collapse(text(node.getAttribute("alt"))).trim();
        if (opts.images && node.getAttribute("src")) return `![${esc(alt)}](${text(absURL(node.getAttribute("src")))})`;
        return "";
      }
      if (t === "INPUT" || t === "TEXTAREA" || t === "SELECT") {
        if (ctx.hidden) return "";
        const v = fieldValue(node);
        if (!v) return "";
        return v === "[x]" || v === "[ ]" ? v + " " : t === "INPUT" && /^(submit|button|reset)$/i.test(node.type) ? v : "`" + collapse(v) + "`";
      }
      const inner = kids(node).map((c) => inline(c, ctx)).join("");
      const trimmed = inner.trim();
      if (!trimmed && t === "A" && opts.links && node.getAttribute("href") && !ctx.hidden) {
        // An icon link is named by its label, its SVG title or its image's alt.
        const svgTitle = node.querySelector("svg title");
        const img = node.querySelector("img[alt]");
        const label = collapse(text(node.getAttribute("aria-label") || (svgTitle && svgTitle.textContent) || (img && img.getAttribute("alt")) || node.getAttribute("title"))).trim();
        if (label && !/^(javascript:|#$)/i.test(node.getAttribute("href").trim())) return `[${esc(label)}](${text(absURL(node.getAttribute("href")))})`;
      }
      if (!trimmed) return inner && /\s/.test(inner) ? " " : "";
      const pad = (s) => (/^\s/.test(inner) ? " " : "") + s + (/\s$/.test(inner) ? " " : "");
      if (t === "A") {
        const href = node.getAttribute("href");
        if (opts.links && href && !/^(javascript:|#$)/i.test(href.trim())) return pad(`[${trimmed.replace(/\n+/g, " ")}](${text(absURL(href))})`);
        return inner;
      }
      if (t === "STRONG" || t === "B") return pad(`**${trimmed}**`);
      if (t === "EM" || t === "I") return pad(`*${trimmed}*`);
      if (t === "CODE" || t === "KBD" || t === "SAMP") return pad("`" + trimmed + "`");
      if (t === "S" || t === "DEL") return pad(`~~${trimmed}~~`);
      return inner;
    }
    const tidy = (s) => s.split("\n").map((l) => l.replace(/ +/g, " ").trim()).filter(Boolean).join("\n");

    // Blocks of a container: inline runs between block children become paragraphs.
    function blocks(node, ctx) {
      const out = [];
      let run = "";
      const end = () => {
        const t = tidy(run);
        if (t) out.push(t);
        run = "";
      };
      for (const c of kids(node)) {
        if (c.nodeType === 3) {
          run += ctx.hidden ? "" : collapse(text(c.data));
          continue;
        }
        if (c.nodeType !== 1 || skipped(c, ctx)) continue;
        if (isInline(c) && !(tag(c) === "IFRAME" || tag(c) === "FRAME")) {
          run += inline(c, ctx);
          continue;
        }
        end();
        append(out, block(c, sub(c, ctx)));
      }
      end();
      return out;
    }
    function list(el, ctx) {
      const ordered = tag(el) === "OL";
      let n = Number(el.getAttribute("start")) || 1;
      const lines = [];
      for (const li of kids(el)) {
        if (li.nodeType !== 1 || skipped(li, ctx)) continue;
        const parts = tag(li) === "LI" ? blocks(li, sub(li, ctx)) : block(li, sub(li, ctx));
        if (!parts.length) continue;
        const marker = ordered ? `${n++}. ` : "- ";
        const itemLines = parts.join("\n").split("\n");
        // Each nesting level indents every line again: charged, so deep
        // nesting cannot multiply the text past the budget.
        if (!B.charge(marker.length * itemLines.length)) break;
        lines.push(marker + itemLines[0]);
        for (let i = 1; i < itemLines.length; i++) lines.push(" ".repeat(marker.length) + itemLines[i]);
      }
      return lines.length ? [lines.join("\n")] : [];
    }
    function table(el, ctx) {
      const rows = take(el.rows).filter((r) => !skipped(r, ctx));
      const layout = !rows.length || el.querySelector("table") || el.getAttribute("role") === "presentation" || rows.every((r) => r.cells.length <= 1);
      if (layout) return blocks(el, ctx);
      const cells = rows.map((r) => take(r.cells));
      let width = 0;
      for (const c of cells) width = Math.max(width, c.length);
      const cell = (c) => tidy(inline(c, sub(c, ctx))).replace(/\n/g, " ").replace(/\|/g, "\\|");
      // Short rows are padded to the widest: charged, so one wide row
      // cannot multiply every other row past the budget.
      const line = (i) => (B.charge(3 * (width - cells[i].length)) ? "| " + cells[i].map(cell).concat(Array(width - cells[i].length).fill("")).join(" | ") + " |" : "");
      const caption = el.caption ? tidy(inline(el.caption, ctx)) : "";
      const lines = [line(0), B.charge(6 * width) ? "|" + " --- |".repeat(width) : ""];
      for (let i = 1; i < rows.length && !B.truncated; i++) lines.push(line(i));
      return caption ? [caption, lines.join("\n")] : [lines.join("\n")];
    }
    function block(el, ctx) {
      return deeper(() => blockElement(el, ctx), []);
    }
    function blockElement(el, ctx) {
      const t = tag(el);
      const h = /^H([1-6])$/.exec(t);
      if (h) {
        const text = tidy(inline(el, ctx)).replace(/\n/g, " ");
        return text ? ["#".repeat(Number(h[1])) + " " + text] : [];
      }
      if (t === "PRE") return ctx.hidden ? [] : ["```\n" + textOf(el).replace(/\n$/, "") + "\n```"];
      if (t === "UL" || t === "OL") return list(el, ctx);
      if (t === "TABLE") return table(el, ctx);
      if (t === "HR") return ["---"];
      if (t === "BLOCKQUOTE") {
        const inner = blocks(el, ctx);
        const quoted = inner.join("\n\n").split("\n");
        return inner.length && B.charge(2 * quoted.length) ? [quoted.map((l) => "> " + l).join("\n")] : [];
      }
      if (t === "IFRAME" || t === "FRAME") {
        if (ctx.hidden) return [];
        if (frames.length >= maxFrames) {
          framesCut = true;
          return [];
        }
        frames.push(A.handleFor(el));
        return [`\u0000F${mark}:${frames.length - 1}\u0000`];
      }
      if (t === "INPUT" || t === "TEXTAREA" || t === "SELECT" || t === "IMG") {
        const s = tidy(inline(el, ctx));
        return s ? [s] : [];
      }
      return blocks(el, ctx);
    }

    let rootEl = document.body || document.documentElement;
    let main = false;
    if (opts.main) {
      // Whether the element shows any text: its text nodes, within the
      // budget, up to the first one that is shown.
      const showsText = (e) => {
        if (typeof e.checkVisibility !== "function") return (e.innerText || "").trim().length > 0;
        const walker = document.createTreeWalker(e, 4 /* NodeFilter.SHOW_TEXT */);
        for (let n = walker.nextNode(); n && B.spend(1); n = walker.nextNode()) {
          if (n.data.trim() && n.parentElement && n.parentElement.checkVisibility({ visibilityProperty: true })) return true;
        }
        return false;
      };
      const visible = (e) => e && style(e).display !== "none" && showsText(e);
      const mainEl = take(document.querySelectorAll("main, [role=main]")).find(visible);
      // Only whether exactly one article shows text matters.
      const articles = [];
      for (const a of take(document.querySelectorAll("article, [role=article]"))) {
        if (visible(a) && articles.push(a) > 1) break;
      }
      if (mainEl) rootEl = mainEl;
      else if (articles.length === 1) rootEl = articles[0];
      else main = true;
    }
    const out = rootEl ? blocks(rootEl, { hidden: false, main }) : [];
    return { blocks: out, frames, mark, report: B.report(), framesCut, nestCut };
  }

  // Structured data by selectors (Playwright syntax: CSS, text=, role=, ...;
  // they reach into shadow roots). A spec is "selector" (text), "selector@attr"
  // (attribute; href and src resolve to absolute URLs), "@attr" or "." (the
  // scope itself), ["spec"] (every match), or an object: { $: "selector", ...fields }
  // is one object per match, an object without $ is one nested object.
  // Matches and values are read within the page-read budget (A.budget):
  // each list keeps at most `limit` matches, every value read is charged,
  // and past the budget the rest reads as null; `report` says where it
  // stopped.
  function extractInFrame(schema, opts) {
    const A = globalThis[Symbol.for("cmux.browserRepl.agent")];
    const B = A.budget();
    const limit = opts.limit || 1000;
    const all = (sel, scope, max) => A.queryAll(sel, scope && scope !== document ? A.handleFor(scope) : undefined, max).map((h) => A.element(h));
    const value = (v) => (v === null || v === undefined || B.truncated ? null : B.fit(String(v)));
    const text = (el) => {
      const t = (el.tagName || "").toUpperCase();
      if (t === "INPUT" || t === "TEXTAREA") return value(el.value);
      if (t === "SELECT") {
        const picked = [];
        for (const o of el.selectedOptions) {
          if (!B.spend(1)) break;
          picked.push(value(o.label || o.text));
        }
        return picked.join(", ");
      }
      return value((el.innerText !== undefined ? el.innerText : el.textContent || "").replace(/[\s ]+/g, " ").trim());
    };
    const split = (spec) => {
      const m = /^(.*?)@([A-Za-z_][\w:.-]*)$/.exec(spec);
      if (m && !/["'\]]/.test(spec.slice(m[1].length))) return [m[1].trim(), m[2]];
      return [spec.trim(), null];
    };
    const read = (el, attr) => {
      if (!el || !B.spend(1)) return null;
      if (!attr) return text(el);
      if ((attr === "href" || attr === "src") && typeof el[attr] === "string" && el[attr]) return value(el[attr]);
      return value(el.getAttribute(attr));
    };
    // One item per match while the budget lasts.
    const each = (els, fn) => {
      const out = [];
      for (const e of els) {
        if (B.truncated) break;
        out.push(fn(e));
      }
      return out;
    };
    const leaf = (spec, scope, many) => {
      const [sel, attr] = split(spec);
      if (!sel || sel === ".") return many ? [read(scope, attr)] : read(scope, attr);
      if (!many) return read(all(sel, scope, 1)[0], attr);
      return each(all(sel, scope, limit), (e) => read(e, attr));
    };
    const run = (spec, scope) => {
      if (typeof spec === "string") return leaf(spec, scope, false);
      if (Array.isArray(spec)) {
        if (spec.length !== 1) throw new Error("page.extract: a list spec has one item: [\"selector\"] or [{ $: \"selector\", ... }]");
        const item = spec[0];
        if (typeof item === "string") return leaf(item, scope, true);
        if (item && typeof item === "object" && Array.isArray(item.__cmuxPairs) && item.__cmuxPairs.some(([k, v]) => k === "$" && typeof v === "string")) return run(item, scope);
        throw new Error("page.extract: a list spec has one item: [\"selector\"] or [{ $: \"selector\", ... }]");
      }
      // Objects travel as key/value pairs both ways, so their key order
      // survives drivers whose JSON does not keep it (the app's).
      if (spec && typeof spec === "object" && Array.isArray(spec.__cmuxPairs)) {
        const entries = spec.__cmuxPairs;
        const perMatch = entries.find(([k]) => k === "$");
        const fields = (s) => ({ __cmuxPairs: entries.filter(([k]) => k !== "$").map(([k, v]) => [k, run(v, s)]) });
        if (perMatch && typeof perMatch[1] === "string") return each(all(perMatch[1], scope, limit), fields);
        return fields(scope);
      }
      throw new Error(`page.extract: expected a selector string, [spec] or an object, got ${JSON.stringify(spec)}`);
    };
    const scope = opts.scope ? A.element(opts.scope) : document;
    const result = run(schema, scope);
    return { value: result, report: B.report() };
  }

  // Text matches with context, like grep over what the page renders.
  // The visible text is read within the page-read budget (A.budget: each
  // node charged, the text joined at most to the budget's characters, the
  // walk iterative), so the regular expression scans at most that much;
  // each context is at most opts.context (capped at 1,000) characters on
  // either side, a match at most 1,000, and what the matches return is
  // charged to a second budget. `report` says where the read stopped.
  function searchTextInFrame(opts) {
    const A = globalThis[Symbol.for("cmux.browserRepl.agent")];
    const B = A.budget();
    const R = A.budget();
    const scope = opts.scope ? A.element(opts.scope) : document.body || document.documentElement;
    const shown = new Map();
    const visible = (el) => {
      if (!el) return false;
      let v = shown.get(el);
      if (v === undefined) {
        if (typeof el.checkVisibility === "function") v = el.checkVisibility({ visibilityProperty: true, contentVisibilityAuto: true });
        else {
          const cs = getComputedStyle(el);
          v = cs.display !== "none" && cs.visibility !== "hidden";
        }
        shown.set(el, v);
      }
      return v;
    };
    const blocks = new Map();
    const blockOf = (el) => {
      if (blocks.has(el)) return blocks.get(el);
      let found = null;
      for (let e = el, i = 0; e && i < 64; e = e.parentElement || (e.getRootNode && e.getRootNode().host), i++) {
        if (!getComputedStyle(e).display.startsWith("inline")) {
          found = e;
          break;
        }
      }
      blocks.set(el, found);
      return found;
    };
    const nodes = [];
    const starts = [];
    let text = "";
    let lastBlock = null;
    // Iterative (a page can nest elements deeper than the stack), one
    // pending sibling per level rather than every child at once. Shadow
    // roots are read in place of the host's light children, as before.
    const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE"]);
    const firstOf = (n) => (n.nodeType === 1 && n.shadowRoot ? n.shadowRoot.firstChild : n.firstChild);
    const stack = [];
    if (firstOf(scope)) stack.push(firstOf(scope));
    while (stack.length && !B.truncated) {
      const n = stack.pop();
      if (n.nextSibling) stack.push(n.nextSibling);
      if (!B.spend(1)) break;
      if (n.nodeType === 3) {
        if (!n.data.trim() || !visible(n.parentElement)) continue;
        const b = blockOf(n.parentElement);
        let piece = (text && b !== lastBlock ? "\n" : "") + n.data.replace(/[\s\u00a0]+/g, " ");
        lastBlock = b;
        piece = B.fit(piece);
        nodes.push(n);
        starts.push(text.length + (piece[0] === "\n" ? 1 : 0));
        text += piece;
        // Matches and their contexts are cut from this text, so a cut in
        // it is settled now (A.budget().settle) and its mark dropped.
        if (B.truncated) text = B.settle(text).replace(/…$/, "");
      } else if (n.nodeType === 1 && !SKIP.has(n.tagName.toUpperCase())) {
        const child = firstOf(n);
        if (child) stack.push(child);
      }
    }
    let re;
    try {
      re = opts.regex ? new RegExp(opts.pattern, opts.caseSensitive ? "g" : "gi") : new RegExp(opts.pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), opts.caseSensitive ? "g" : "gi");
    } catch (e) {
      throw new Error(`page.searchText: invalid pattern: ${e.message}`);
    }
    const context = Math.max(0, Math.min(1000, Math.floor(Number(opts.context) || 0)));
    const limit = Math.max(0, Math.floor(Number(opts.limit) || 0));
    const cap = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
    const matches = [];
    let total = 0;
    let m;
    while ((m = re.exec(text))) {
      if (!m[0].length) {
        re.lastIndex++;
        continue;
      }
      total++;
      if (matches.length >= limit || R.truncated) continue;
      let lo = 0;
      let hi = starts.length - 1;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (starts[mid] <= m.index) lo = mid;
        else hi = mid - 1;
      }
      const a = Math.max(0, m.index - context);
      const b = Math.min(text.length, m.index + Math.min(m[0].length, 1000) + context);
      const el = nodes[lo] && nodes[lo].parentElement;
      const match = R.fit(cap(m[0], 1000));
      const around = R.fit((a > 0 ? "…" : "") + text.slice(a, b).replace(/\n/g, " ").trim() + (b < text.length ? "…" : ""));
      if (R.truncated) continue;
      matches.push({ match, context: around, handle: el ? A.handleFor(el) : null });
    }
    return { total, matches, report: B.truncated ? B.report() : R.truncated ? R.report() : null };
  }

  // Options are read within the page-read budget (A.budget): each element
  // of an ARIA popup walked, each <select> option, and their labels and
  // values are charged; `report` says where it stopped.
  function dropdownInFrame(handle) {
    const A = globalThis[Symbol.for("cmux.browserRepl.agent")];
    const B = A.budget();
    const el = A.element(handle);
    const clean = (s) => (s || "").replace(/[\s ]+/g, " ").trim();
    const fit = (s) => (s === null || s === undefined ? s : B.fit(String(s)));
    if (el.tagName && el.tagName.toUpperCase() === "SELECT") {
      const options = [];
      const all = el.options;
      for (let index = 0; index < all.length && B.spend(1); index++) {
        const o = all[index];
        options.push({ index, label: fit(o.label || clean(o.text)), value: fit(o.value), selected: o.selected, disabled: o.disabled });
      }
      return { kind: "select", multiple: el.multiple, options, report: B.report() };
    }
    const rootNode = el.getRootNode();
    const byId = (id) => (rootNode.getElementById ? rootNode.getElementById(id) : document.getElementById(id));
    const role = el.getAttribute("role");
    let popup = null;
    if (role === "listbox" || role === "menu" || role === "tree" || role === "radiogroup") popup = el;
    else {
      for (const attr of ["aria-controls", "aria-owns"]) {
        for (const id of (el.getAttribute(attr) || "").split(/\s+/).filter(Boolean)) popup = popup || byId(id);
      }
      if (!popup) popup = el.querySelector("[role=listbox], [role=menu], [role=tree]");
    }
    if (!popup) return { kind: "none", options: [] };
    // The popup's elements are walked one at a time, each one charged, so
    // the read stops at the budget before it lists a page-sized match list.
    const OPTION = "[role=option], [role=menuitem], [role=menuitemradio], [role=menuitemcheckbox], [role=treeitem], [role=radio]";
    const options = [];
    const walker = document.createTreeWalker(popup, 1 /* NodeFilter.SHOW_ELEMENT */);
    for (let o = walker.nextNode(); o && B.spend(1); o = walker.nextNode()) {
      if (!o.matches(OPTION)) continue;
      if (typeof o.checkVisibility === "function" && !o.checkVisibility({ visibilityProperty: true })) continue;
      options.push({
        index: options.length,
        label: fit(clean(o.getAttribute("aria-label") || o.innerText || o.textContent)),
        value: fit(o.getAttribute("data-value") || o.getAttribute("value") || null),
        selected: o.getAttribute("aria-selected") === "true" || o.getAttribute("aria-checked") === "true",
        disabled: o.getAttribute("aria-disabled") === "true",
        handle: A.handleFor(o),
      });
    }
    return { kind: "aria", multiple: popup.getAttribute("aria-multiselectable") === "true", options, report: B.report() };
  }

  function scrollInfoInFrame(handle) {
    const A = globalThis[Symbol.for("cmux.browserRepl.agent")];
    const el = handle ? A.element(handle) : null;
    const doc = document.scrollingElement || document.documentElement;
    const target = el || doc;
    const vh = el ? el.clientHeight : innerHeight;
    const y = el ? el.scrollTop : scrollY;
    const r1 = (n) => Math.round(n * 10) / 10;
    return {
      x: Math.round(el ? el.scrollLeft : scrollX),
      y: Math.round(y),
      viewportHeight: vh,
      scrollHeight: target.scrollHeight,
      pagesAbove: vh ? r1(y / vh) : 0,
      pagesBelow: vh ? r1(Math.max(0, target.scrollHeight - y - vh) / vh) : 0,
    };
  }

  // Search engine results pages, parsed in a blank tab's DOM parser.
  function parseResults(arg) {
    const doc = new DOMParser().parseFromString(arg.html, "text/html");
    const clean = (s) => (s || "").replace(/[\s ]+/g, " ").trim();
    const abs = (href) => {
      try {
        return new URL(href, arg.base).href;
      } catch (e) {
        return null;
      }
    };
    const out = [];
    const seen = new Set();
    const add = (title, url, snippet) => {
      if (!title || !url || !/^https?:/.test(url) || seen.has(url) || out.length >= arg.limit) return;
      seen.add(url);
      out.push({ title, url, snippet: snippet || "" });
    };
    if (arg.engine === "duckduckgo") {
      for (const r of doc.querySelectorAll(".result, .web-result")) {
        if (r.classList.contains("result--ad")) continue;
        const a = r.querySelector("a.result__a");
        if (!a) continue;
        let url = abs(a.getAttribute("href"));
        try {
          const u = new URL(url);
          if (/duckduckgo\.com$/.test(u.hostname) && u.pathname === "/l/" && u.searchParams.get("uddg")) url = u.searchParams.get("uddg");
        } catch (e) {}
        add(clean(a.textContent), url, clean((r.querySelector(".result__snippet") || {}).textContent));
      }
      return { results: out, blocked: !out.length && !!doc.querySelector(".anomaly-modal, #challenge-form, .challenge-form") };
    }
    for (const r of doc.querySelectorAll("#b_results > li.b_algo, li.b_algo")) {
      const a = r.querySelector("h2 a");
      if (!a) continue;
      let url = abs(a.getAttribute("href"));
      try {
        const u = new URL(url);
        const enc = u.pathname === "/ck/a" && u.searchParams.get("u");
        if (enc && enc.startsWith("a1")) url = atob(enc.slice(2).replace(/-/g, "+").replace(/_/g, "/"));
      } catch (e) {}
      add(clean(a.textContent), url, clean((r.querySelector(".b_caption p, .b_lineclamp2, .b_lineclamp3, .b_algoSlug") || {}).textContent));
    }
    return { results: out, blocked: !out.length && !!doc.querySelector("#b_captcha, .captcha") };
  }

  const ENGINES = {
    duckduckgo: "https://html.duckduckgo.com/html/?q=%s",
    bing: "https://www.bing.com/search?q=%s",
  };

  // ---------------------------------------------------------------------------

  const fnSource = (fn) => fn.toString();
  const agentCall = (frame, fn, ...args) => frame._call("agent", fnSource(fn), args, undefined, fn.name);
  const errCode = (e) => e && (e.code || (e.cause && e.cause.code));

  function install(ctx) {
    const { session, host, globals, sessionApi, fetch, fs, path, currentPage, show } = ctx;
    const print = (level, text) => {
      try {
        host.print(level, text);
      } catch {}
    };

    // ---- secrets -------------------------------------------------------------
    // Values live in the native session (BrowserReplSecretStore), never in
    // this context: secret(name) is a handle, the session substitutes the
    // value into input.insertText for the driver, which types it only into a
    // frame whose own origin matches the secret's domains, and the session
    // masks every value in output, errors, driver results, events, fetch
    // bodies and written files. Agent code runs in this context, so nothing
    // here is the guard; these functions only shape the API.
    const SecretBrand = new WeakSet();
    class Secret {
      constructor(name) {
        this.name = name;
        SecretBrand.add(this);
        Object.freeze(this);
      }
      toString() {
        return `<secret:${this.name}>`;
      }
      toJSON() {
        return this.toString();
      }
    }
    Object.freeze(Secret.prototype);
    const isSecret = (v) => v !== null && typeof v === "object" && SecretBrand.has(v);
    const secretsHost = (op, args) => host.secrets(op, args || {});
    // { name, domains, totp } in that key order, whatever order the host used.
    const described = (d) => ({ name: d.name, domains: d.domains, totp: d.totp });
    const secrets = Object.freeze({
      // set(name, value, { domains, totp }): the value is typed only into
      // frames on those domains and is masked as <secret:name> everywhere.
      set(name, value, options) {
        return described(secretsHost("set", { name, value, domains: options && options.domains, totp: !!(options && options.totp) }));
      },
      // Reference C's sensitive_data shape: { "<domain pattern>": { name: value } },
      // as an object or a JSON file path (read by the native session, so the
      // values never enter this context). A value { value, totp } is accepted.
      // A weak value (shorter than 8 characters, or a common password)
      // is refused unless options.allowWeak is true.
      load(source, options) {
        const allowWeak = !!(options && options.allowWeak === true);
        if (typeof source === "string") return secretsHost("load", { path: source, allowWeak }).map(described);
        if (!source || typeof source !== "object" || Array.isArray(source)) throw new Error("secrets.load: expected { \"<domain pattern>\": { name: value } }");
        return secretsHost("load", { object: source, allowWeak }).map(described);
      },
      list: () => secretsHost("list").map(described),
      has: (name) => secretsHost("has", { name }),
      delete: (name) => secretsHost("delete", { name }),
      clear: () => {
        secretsHost("clear");
      },
    });
    function secret(name) {
      if (!secretsHost("has", { name })) throw new Error(`secret(${JSON.stringify(name)}): no such secret; register it with secrets.set(name, value, { domains }) or secrets.load(file)`);
      return new Secret(name);
    }
    const anySecrets = () => secretsHost("list").length > 0;

    // ---- domain policy -------------------------------------------------------
    // The policy lives in the native session, which checks navigations, new
    // tabs, every fetch hop and subresources (content rules) itself, and
    // refuses reads and input on a tab whose page it blocks. These wrappers
    // give early errors and keep the log of blocked navigations.
    const policyHost = (op, args) => host.policy(op, args || {});
    const policyLog = [];
    const blockedTabs = new Map(); // targetId -> { url, reason } reported by the driver
    const policyActive = () => {
      const p = policyHost("get");
      return !!(p.allowed || p.prohibited.length || p.blockIPs);
    };
    const urlReason = (url) => policyHost("check", { url: String(url) });
    function checkURL(title, url) {
      const reason = urlReason(url);
      if (reason) {
        policyLog.push({ url: String(url), reason, at: new Date(session.now()).toISOString(), blocked: "before" });
        throw new Error(`${title}: ${url} is blocked: ${reason}`);
      }
    }
    function setPatterns(kind, title, list, options) {
      if (list === undefined) {
        const p = policyHost("get");
        return kind === "allowed" ? p.allowed : p.prohibited;
      }
      if (list !== null && !Array.isArray(list)) throw new Error(`${title}: expected an array of domain patterns or null, got ${JSON.stringify(list)}`);
      const p = policyHost("set", { [kind]: list, lock: !!(options && options.lock), title });
      return kind === "allowed" ? p.allowed : p.prohibited;
    }

    // ---- browser-context options (session.configure) -------------------------------
    const contextConfig = {};
    async function configure(options) {
      if (options === null || typeof options !== "object" || Array.isArray(options)) throw new Error(`session.configure: options: expected an object, got ${JSON.stringify(options)}`);
      const known = ["userAgent", "extraHTTPHeaders", "permissions", "proxy"];
      const unknown = Object.keys(options).filter((k) => !known.includes(k));
      if (unknown.length) throw new Error(`session.configure: unknown option ${unknown.map((k) => JSON.stringify(k)).join(", ")}; expected ${known.join(", ")}`);
      const params = {};
      if ("userAgent" in options) {
        if (options.userAgent !== null && typeof options.userAgent !== "string") throw new Error("session.configure: userAgent: expected a string or null");
        params.userAgent = options.userAgent;
      }
      if ("extraHTTPHeaders" in options) {
        const h = options.extraHTTPHeaders;
        if (h !== null && (typeof h !== "object" || Array.isArray(h) || Object.values(h).some((v) => typeof v !== "string"))) throw new Error("session.configure: extraHTTPHeaders: expected { name: string value } or null");
        params.extraHTTPHeaders = h || {};
      }
      if ("permissions" in options) {
        const list = options.permissions;
        if (list !== null && (!Array.isArray(list) || list.some((v) => typeof v !== "string"))) throw new Error("session.configure: permissions: expected an array of permission names or null");
        params.permissions = list || [];
      }
      if ("proxy" in options) {
        const px = options.proxy;
        if (px !== null && (typeof px !== "object" || typeof px.server !== "string" || !px.server)) throw new Error("session.configure: proxy: expected { server, username?, password?, bypass? } or null");
        params.proxy = px;
      }
      const result = await session.driver.call("session.configure", params);
      for (const [k, v] of Object.entries(params)) {
        if (v === null || (Array.isArray(v) && !v.length) || (k === "extraHTTPHeaders" && !Object.keys(v).length)) delete contextConfig[k];
        else contextConfig[k] = k === "proxy" ? Object.fromEntries(["server", "username", "bypass"].filter((f) => v[f] !== undefined).map((f) => [f, v[f]])) : v;
      }
      const out = { ...contextConfig };
      if (result && result.proxy) out.proxyAppliesTo = "tabs opened from now on";
      return out;
    }

    // ---- downloads -------------------------------------------------------------
    const downloads = [];
    const downloadsById = new Map();

    // ---- recording -------------------------------------------------------------
    let recorder = null;
    let recordCount = 0;
    const RECORDED = new Set(["tab.navigate", "tab.history", "tab.reload", "tabs.open", "tabs.close", "input.mouse", "input.key", "input.insertText", "input.drag", "input.setFiles", "dialog.respond", "filechooser.respond"]);
    const NAVIGATIONS = new Set(["tab.navigate", "tab.history", "tab.reload"]);
    function traceParams(method, p) {
      const o = {};
      if (p.url !== undefined) o.url = p.url;
      if (method === "input.mouse") Object.assign(o, { type: p.type, x: p.x, y: p.y, button: p.button, deltaX: p.deltaX, deltaY: p.deltaY });
      // With secrets registered, keys and inserted text stay out of the trace
      // (a secret typed key by key would otherwise be spelled out there).
      const quiet = anySecrets();
      if (method === "input.key") Object.assign(o, { type: p.type, modifiers: p.modifiers }, quiet ? {} : { key: p.key });
      if (method === "input.insertText") o.text = p.secret ? `<secret:${p.secret}>` : quiet ? `<${String(p.text).length} characters>` : p.text;
      if (method === "input.setFiles") o.files = (p.files || []).map((f) => f.name);
      if (method === "tab.history") o.delta = p.delta;
      if (method === "dialog.respond") o.accept = p.accept;
      return o;
    }
    async function recordFrame(page) {
      if (!recorder || !recorder.screenshots || page._closed || recorder.busy) return;
      recorder.busy = true;
      try {
        const r = await session.call("tab.screenshot", { targetId: page._targetId, format: "png" });
        const file = path.join(recorder.dir, `frame-${String(++recorder.frames).padStart(4, "0")}.png`);
        fs.writeFileSync(file, Buffer.from(r.base64, "base64"));
        recorder.frameFiles.push(file);
        return file;
      } catch {
        return null;
      } finally {
        recorder.busy = false;
      }
    }
    function trace(entry) {
      if (!recorder) return;
      recorder.actions++;
      fs.appendFileSync(recorder.trace, JSON.stringify(entry) + "\n");
    }

    // ---- hooks -------------------------------------------------------------------
    // Secrets in captures are masked by the driver: it hides the fields it
    // typed a secret into, and text holding a value in frames on that
    // secret's domains, for the length of the capture.
    const TITLES = { "tab.navigate": "page.goto", "tabs.open": "tabs.open" };
    const blockedMessage = (b) => `navigation to ${b.url} was blocked: ${b.reason}`;
    const hooks = {
      isSecret,
      checkURL,
      async beforeCall(method, params) {
        // A cancelled navigation is reported to the action that caused it; a
        // report that came in after that action ended is dropped when the
        // tab's next action starts.
        if (params && params.targetId && /^(tab\.(navigate|history|reload)|input\.)/.test(method)) blockedTabs.delete(params.targetId);
        if ((method === "tab.navigate" || method === "tabs.open") && params && params.url) checkURL(TITLES[method], params.url);
      },
      afterCall(method, params, promise) {
        if (!recorder && !(NAVIGATIONS.has(method) || method === "tabs.open")) return promise;
        return promise.then(async (r) => {
          if (recorder && RECORDED.has(method) && !(method === "input.mouse" && params.type === "move") && !(method === "input.key" && params.type === "up")) {
            const entry = { t: new Date(session.now()).toISOString(), tab: params.targetId, method, ...traceParams(method, params) };
            if (NAVIGATIONS.has(method) || method === "tabs.open") {
              const page = session.pages.get(params.targetId || (r && r.targetId));
              if (page) entry.frame = await recordFrame(page);
            }
            trace(entry);
          }
          return r;
        }, (e) => {
          // The driver cancelled this navigation (a redirect to a blocked
          // page) and reported it while the call was running.
          const reported = NAVIGATIONS.has(method) && params && params.targetId && blockedTabs.get(params.targetId);
          if (reported) {
            blockedTabs.delete(params.targetId);
            throw new Error(`${TITLES[method] || method}: ${blockedMessage(reported)}; the tab stayed on its page`);
          }
          // The driver refused a navigation the policy blocks. Other
          // refusals (a frame or input the policy blocks) pass unchanged.
          if (e && e.code === "blocked" && (NAVIGATIONS.has(method) || method === "tabs.open")) {
            policyLog.push({ url: String(params.url || ""), reason: String(e.message).replace(/^.* is blocked: /, ""), at: new Date(session.now()).toISOString(), blocked: "before" });
            throw new Error(`${TITLES[method] || method}: ${e.message}`);
          }
          throw e;
        });
      },
      onEvent(event, payload) {
        return payload;
      },
      afterEvent(event, p) {
        if (event === "download.started") {
          const d = { id: p.downloadId, url: p.url, suggestedFilename: p.suggestedFilename, tab: p.targetId, state: "started", path: null, error: null, startedAt: new Date(session.now()).toISOString() };
          downloads.push(d);
          downloadsById.set(p.downloadId, d);
          trace({ t: d.startedAt, tab: p.targetId, event: "download", url: p.url, suggestedFilename: p.suggestedFilename });
        } else if (event === "download.finished") {
          const d = downloadsById.get(p.downloadId);
          if (d) Object.assign(d, { state: p.error ? "failed" : "finished", path: p.path || null, error: p.error || null });
        } else if (event === "tab.replaced" && p.reason) {
          // The session narrowed its domain policy: cmux loaded the page of
          // each tab it opened again, ending connections opened before.
          print("warn", `# tab ${p.targetId}: ${p.reason}`);
        } else if (event === "navigation.blocked") {
          // The driver cancelled a navigation of a tab the session opened (a
          // link, redirect or script): the tab stays where it was.
          policyLog.push({ url: p.url, reason: p.reason, at: new Date(session.now()).toISOString(), blocked: "cancelled" });
          blockedTabs.set(p.targetId, { url: p.url, reason: p.reason });
          print("warn", `# ${blockedMessage(p)}; the tab stayed on its page`);
        } else if (event === "tab.created" && p.url && p.openerTargetId) {
          const reason = urlReason(p.url);
          if (reason && p.userOwned) {
            // A window a user's page opened while it handled the session's
            // input: the tab is the user's, and the policy only keeps the
            // session's reads and input out of it; it is never closed.
            policyLog.push({ url: p.url, reason, at: new Date(session.now()).toISOString(), blocked: "popup" });
            print("warn", `# a new tab for ${p.url} is the user's and stays open, but the session may not use it: ${reason}`);
          } else if (reason) {
            policyLog.push({ url: p.url, reason, at: new Date(session.now()).toISOString(), blocked: "popup" });
            print("warn", `# a new tab for ${p.url} was closed: ${reason}`);
            session.call("tabs.close", { targetId: p.targetId }).catch(() => {});
          }
        }
      },
      async afterAction(page) {
        const blocked = blockedTabs.get(page._targetId);
        if (blocked) {
          blockedTabs.delete(page._targetId);
          throw new Error(`${blockedMessage(blocked)}; the tab stayed on ${page.url()}`);
        }
        if (recorder) {
          const file = await recordFrame(page);
          if (file) trace({ t: new Date(session.now()).toISOString(), tab: page._targetId, event: "after-action", url: page.url(), frame: file });
        }
      },
    };
    // Agent code can reach the session object; the hooks stay fixed. They
    // are conveniences: the guards are native and do not depend on them.
    Object.freeze(hooks);
    Object.defineProperty(session, "agentTools", { value: hooks, writable: false, configurable: false, enumerable: false });

    // ---- storage state -------------------------------------------------------------
    // Default scope: the sites (registrable domains) of one tab, so a saved
    // state never carries the rest of the user's profile by accident.
    // { all: true } saves everything; { urls } saves what those URLs see.
    // The native session answers a host's site from the system's Public
    // Suffix List, the one the driver scopes cookies.clear with.
    const siteOf = (hostname) => policyHost("site", { host: String(hostname || "") });
    async function storageState(options = {}, fromPage) {
      if (options === null || typeof options !== "object") throw new Error(`session.storageState: options: expected an object, got ${JSON.stringify(options)}`);
      // An empty list is no scope: it means the current tab's site, as an
      // absent one does (the native cookie store reads an empty list as no
      // filter, the whole profile). Each URL must be absolute http(s).
      const listed = options.urls === undefined || options.urls === null ? [] : [].concat(options.urls);
      for (const u of listed) {
        let parsed = null;
        try { parsed = typeof u === "string" ? new core.URL(u) : null; } catch { parsed = null; }
        if (!parsed || !/^https?:$/.test(parsed.protocol)) throw new Error(`session.storageState: urls: expected absolute http(s) URLs, got ${JSON.stringify(u)}`);
      }
      const urls = listed.length ? listed : null;
      const page = fromPage || currentPage();
      let site = null;
      if (!options.all && !urls) {
        const url = page && !page._closed ? String(page.url()) : "";
        const hostname = /^https?:/i.test(url) ? new core.URL(url).hostname : "";
        if (!hostname) throw new Error(`session.storageState: the current tab (${url || "none"}) has no site to scope to; open the site first, or pass { all: true } for the whole profile or { urls: [...] }`);
        site = siteOf(hostname);
      }
      const inScope = (hostname) => site === null || siteOf(hostname) === site;
      // The cookies of the page's own data store (cookieScope).
      const cookies = (await session.call("cookies.get", { ...cookieScope(page), ...(urls ? { urls } : {}) })).filter((c) => inScope(String(c.domain || "")));
      // localStorage only from the open tabs in that store (storeTabs).
      // It is page-controlled, so every frame's is read within what the
      // call's one page-read budget has left (READ_NODES items and
      // READ_SIZE characters of names and values over all frames), and
      // past it the call fails with the note rather than save part of a
      // state.
      const { targetIds } = await storeTabs(page);
      const origins = new Map();
      const budget = { left: READ_NODES, sizeLeft: READ_SIZE };
      for (const page of [...session.pages.values()]) {
        if (page._closed || !targetIds.has(page._targetId)) continue;
        for (const frame of [page._mainFrame, ...page._frames.values()]) {
          if (frame._detached) continue;
          const r = await frame._call("agent", localStorageOfFrame, [Math.max(1, budget.left), Math.max(1, budget.sizeLeft)], [], "localStorage").catch(() => null);
          if (!r || !r.origin || r.origin === "null") continue;
          const report = r.report || {};
          budget.left -= Math.max(0, Number(report.visited) || 0);
          budget.sizeLeft -= Math.max(0, Number(report.size) || 0);
          if (report.truncated || budget.left < 0 || budget.sizeLeft < 0) {
            const cut = { truncated: report.truncated || (budget.left < 0 ? "nodes" : "size"), maxNodes: READ_NODES, maxSize: READ_SIZE };
            throw new Error(`session.storageState: ${core.readCutNote("localStorage", cut)}; pass { urls } to save fewer origins`);
          }
          if (urls && !urls.some((u) => new core.URL(u).origin === r.origin)) continue;
          if (!inScope(new core.URL(r.origin).hostname)) continue;
          origins.set(r.origin, r.items.map(([name, value]) => ({ name, value })));
        }
      }
      const state = { cookies, origins: [...origins].map(([origin, localStorage]) => ({ origin, localStorage })) };
      if (options.path) fs.writeFileSync(options.path, JSON.stringify(state, null, 2));
      return state;
    }
    // The frame's origin and localStorage items, read within a page-read
    // budget of `maxNodes` items and `maxSize` characters (A.budget): each
    // item is charged before its name and value are kept, and the read
    // stops at the budget (`report.truncated` says why). Null where the
    // frame's storage cannot be read (a sandboxed frame).
    const localStorageOfFrame = `(maxNodes, maxSize) => {
      try {
        const B = globalThis[Symbol.for("cmux.browserRepl.agent")].budget({ maxNodes, maxSize });
        const storage = localStorage;
        const items = [];
        const count = storage.length;
        for (let i = 0; i < count && B.spend(1); i++) {
          const name = storage.key(i);
          if (name === null) continue;
          const value = storage.getItem(name);
          if (!B.charge(name.length + (value === null ? 0 : value.length))) break;
          items.push([name, value === null ? "" : value]);
        }
        return { origin: location.origin, items, report: B.report() };
      } catch (e) {
        return null;
      }
    }`;
    // A page's cookie calls name its tab, so the driver uses that tab's data
    // store (a private tab's, or the session's proxy store), not another's.
    function cookieScope(page) {
      return page && !page._closed && typeof page._cookieScope === "function" ? page._cookieScope() : {};
    }
    // The data store the page's cookie calls use (`tabs.dataStore`), and the
    // open tabs in it. localStorage belongs to a store too, so storage state
    // reads and writes it only through those tabs, never through a tab on
    // the same origin in another store. A driver without `tabs.dataStore`
    // gets the page's own tab only.
    async function storeTabs(page) {
      const scope = cookieScope(page);
      let dataStore;
      try {
        ({ dataStore } = await session.call("tabs.dataStore", scope));
      } catch (e) {
        if (errCode(e) !== "unsupported") throw e;
        return { dataStore: undefined, targetIds: new Set(scope.targetId ? [scope.targetId] : []) };
      }
      const list = await session.call("tabs.list", { all: true });
      return { dataStore, targetIds: new Set(list.filter((t) => t.dataStore === dataStore).map((t) => t.targetId)) };
    }
    async function setStorageState(source, fromPage) {
      const state = typeof source === "string" ? JSON.parse(fs.readFileSync(source, "utf8")) : source;
      if (!state || typeof state !== "object" || (!Array.isArray(state.cookies) && !Array.isArray(state.origins))) {
        throw new Error("session.setStorageState: expected { cookies, origins } (Playwright's storage state) or a path to one");
      }
      const target = fromPage || currentPage();
      if (state.cookies && state.cookies.length) await session.call("cookies.set", { ...cookieScope(target), cookies: state.cookies });
      let restored = 0;
      let store = null;
      for (const { origin, localStorage } of state.origins || []) {
        if (!localStorage || !localStorage.length) continue;
        checkURL("session.setStorageState", origin);
        let canonical;
        try {
          canonical = new core.URL(origin).origin;
        } catch {
          canonical = "null";
        }
        if (!/^https?:\/\//.test(canonical)) throw new Error(`session.setStorageState: ${JSON.stringify(origin)} is not an http(s) origin`);
        // An open tab on the origin in the page's data store takes the
        // items; otherwise a background tab of that store loads the origin,
        // takes them and closes.
        if (!store) store = await storeTabs(target);
        let page = [...session.pages.values()].find((p) => !p._closed && store.targetIds.has(p._targetId) && /^https?:/.test(p.url()) && new core.URL(p.url()).origin === canonical);
        const temp = !page;
        if (temp) {
          page = await session.newPage(undefined, { background: true, dataStore: store.dataStore });
          await page.goto(origin + "/", { waitUntil: "domcontentloaded" });
        }
        try {
          // The origin is checked in the document that takes the items, in
          // the same turn as the writes: a redirect, or a navigation since
          // the tab was listed, leaves another origin there, which must not
          // get this origin's items.
          const wrote = await page._mainFrame._call("agent", "(want, items) => { if (location.origin !== want) return location.origin; for (const { name, value } of items) localStorage.setItem(name, value); return null; }", [canonical, localStorage]);
          if (wrote !== null) throw new Error(`session.setStorageState: ${origin} shows ${wrote} instead (a redirect or navigation); its localStorage was not written there`);
          restored++;
        } finally {
          if (temp) await page.close().catch(() => {});
        }
      }
      return { cookies: (state.cookies || []).length, origins: restored };
    }

    session.agentStorage = { storageState, setStorageState };

    // ---- session members -------------------------------------------------------------
    Object.assign(sessionApi, {
      // Navigations, new tabs, fetch and sites tools may reach only these
      // domains; null clears. { lock: true } fixes the policy for the session.
      allowedDomains: (list, options) => setPatterns("allowed", "session.allowedDomains", list, options),
      prohibitedDomains: (list, options) => setPatterns("prohibited", "session.prohibitedDomains", list, options),
      blockIPAddresses(on) {
        if (on === undefined) return policyHost("get").blockIPs;
        return policyHost("set", { blockIPs: !!on, title: "session.blockIPAddresses" }).blockIPs;
      },
      blockedNavigations: () => policyLog.map((e) => ({ ...e })),
      // Playwright browser-context options for the tabs this session created:
      // { userAgent, extraHTTPHeaders, permissions, proxy }. null clears one.
      configure,
      configuration: () => JSON.parse(JSON.stringify(contextConfig)),
      storageState,
      setStorageState,
      downloads: () => downloads.map((d) => ({ ...d })),
      // Records each action of this session: trace.jsonl (method, URL, time),
      // a PNG after each action and navigation, and on stop() run.png, an
      // animated PNG of the run.
      record(options = {}) {
        if (recorder) throw new Error(`session.record: already recording to ${recorder.dir}; call stop() on it first`);
        const dir = options.dir ? path.resolve(String(options.dir)) : path.join(host.tmpdir, `record-${++recordCount}`);
        fs.mkdirSync(dir, { recursive: true });
        const r = { dir, trace: path.join(dir, "trace.jsonl"), screenshots: options.screenshots !== false, frames: 0, frameFiles: [], actions: 0, busy: false };
        fs.writeFileSync(r.trace, "");
        recorder = r;
        return {
          dir,
          async stop() {
            if (recorder === r) recorder = null;
            const result = { dir, trace: r.trace, actions: r.actions, frames: r.frameFiles.length, animation: null };
            if (r.frameFiles.length) {
              const apng = buildApng(r.frameFiles.map((f) => fs.readFileSync(f)), options.frameMs || 800);
              result.animation = path.join(dir, "run.png");
              fs.writeFileSync(result.animation, apng.bytes);
            }
            return result;
          },
        };
      },
    });

    // ---- search ------------------------------------------------------------------------
    async function search(query, options = {}) {
      if (typeof query !== "string" || !query.trim()) throw new Error(`search: query: expected a non-empty string, got ${JSON.stringify(query)}`);
      const engine = options.engine || "duckduckgo";
      const limit = options.limit === undefined ? 10 : options.limit;
      if (!Number.isInteger(limit) || limit < 1 || limit > 50) throw new Error(`search: limit: expected 1 to 50, got ${JSON.stringify(limit)}`);
      if (engine === "google" && !options.endpoint) {
        if (!globals.sites || !globals.sites.googleSearch) throw new Error("search: Google search needs sites.googleSearch");
        return (await globals.sites.googleSearch.search(query, { limit })).map((r) => ({ title: r.title, url: r.url, snippet: r.snippet || "" }));
      }
      if (!ENGINES[engine]) throw new Error(`search: engine: expected one of duckduckgo, bing, google, got ${JSON.stringify(engine)}`);
      const template = options.endpoint || ENGINES[engine];
      const url = template.replace(/%s|\{query\}/, encodeURIComponent(query).replace(/%20/g, "+"));
      const res = await fetch(url, { headers: { "accept-language": "en-US,en;q=0.9" } });
      if (!res.ok && res.status !== 202) throw new Error(`search: ${engine} returned HTTP ${res.status}`);
      const html = await res.text();
      const page = await session.newPage(undefined, { background: true });
      try {
        const r = await page.evaluate(parseResults, { html, engine, base: url, limit });
        if (r.blocked) throw new Error(`search: ${engine} showed a CAPTCHA; cmux does not solve CAPTCHAs. Try another engine, or open ${url} with tabs.open() and let the user answer it`);
        return r.results;
      } finally {
        await page.close().catch(() => {});
      }
    }

    // ---- custom tools ------------------------------------------------------------------
    const registry = new Map();
    const TYPES = { string: "string", number: "number", boolean: "boolean", object: "object", array: "array", any: "any" };
    function checkArgs(name, params, args) {
      if (!params) return;
      if (args === null || typeof args !== "object" || Array.isArray(args)) throw new Error(`tools.${name}: expected an object of arguments, got ${JSON.stringify(args)}`);
      for (const [key, spec] of Object.entries(params)) {
        const optional = spec.endsWith("?");
        const type = spec.replace(/\?$/, "");
        const v = args[key];
        if (v === undefined) {
          if (!optional) throw new Error(`tools.${name}: ${key}: required (${type})`);
          continue;
        }
        const actual = Array.isArray(v) ? "array" : v === null ? "null" : typeof v;
        if (type !== "any" && actual !== type) throw new Error(`tools.${name}: ${key}: expected ${type}, got ${actual}`);
      }
      for (const key of Object.keys(args)) if (!(key in params)) throw new Error(`tools.${name}: unknown argument ${key}; expected ${Object.keys(params).join(", ") || "none"}`);
    }
    const tools = {
      // register(name, fn, { description, params: { key: "string" | "number?" ... }, domains })
      register(name, fn, options = {}) {
        if (typeof name !== "string" || !/^[A-Za-z_$][\w$]*$/.test(name) || name in tools) throw new Error(`tools.register: name: expected an identifier that is not ${Object.keys(tools).join(", ")}, got ${JSON.stringify(name)}`);
        if (typeof fn !== "function") throw new Error(`tools.register: ${name}: expected a function`);
        const params = options.params || null;
        if (params) for (const [k, t] of Object.entries(params)) if (typeof t !== "string" || !TYPES[t.replace(/\?$/, "")]) throw new Error(`tools.register: ${name}: params.${k}: expected one of ${Object.keys(TYPES).join(", ")} (add ? when optional), got ${JSON.stringify(t)}`);
        const domains = options.domains ? options.domains.map((d) => parsePattern(d, "tools.register", (name) => policyHost("publicSuffix", { name }))) : null;
        const entry = { name, fn, description: String(options.description || ""), params, domains };
        if (registry.has(name)) delete tools[registry.get(name).name];
        registry.set(name, entry);
        Object.defineProperty(tools, name, { value: (args) => tools.call(name, args), enumerable: false, configurable: true });
        return tools.describe(name);
      },
      describe(name) {
        const e = registry.get(name);
        if (!e) throw new Error(`tools: no tool ${JSON.stringify(name)}; see tools.list()`);
        return { name: e.name, description: e.description, params: e.params, domains: e.domains && e.domains.map((d) => d.raw) };
      },
      list: () => [...registry.keys()].map((n) => tools.describe(n)),
      async call(name, args = {}) {
        const e = registry.get(name);
        if (!e) throw new Error(`tools: no tool ${JSON.stringify(name)}; see tools.list()`);
        checkArgs(name, e.params, args);
        const page = currentPage();
        if (e.domains && !e.domains.some((d) => urlMatches(page.url(), d, false))) throw new Error(`tools.${name}: available only on ${e.domains.map((d) => d.raw).join(", ")}; the current tab is ${page.url()}`);
        return e.fn(args, { page, session: sessionApi, tabs: ctx.tabs });
      },
      unregister(name) {
        if (!registry.has(name)) return false;
        registry.delete(name);
        delete tools[name];
        return true;
      },
    };

    Object.assign(globals, { secret, secrets, search, tools });
  }

  // ---------------------------------------------------------------------------
  // Page and Locator additions.

  const P = core.Page.prototype;

  // A page read cut at the page-read budget returns what it read; this
  // line says so in the call's output.
  function printCut(page, title, report, rest) {
    try {
      page._session.host.print("warn", `# ${title}: ${core.readCutNote("it", report)}; ${rest}`);
    } catch {}
  }

  // The page-read budget of one page.markdown(), over all its frames
  // (page-agent.js readBudget: the snapshot's nodes and characters), and
  // at most MARKDOWN_FRAMES iframes. Frames are read one after another, so
  // each gets what the frames before it left and the page's frame count
  // sets no number of calls in flight.
  const MARKDOWN_FRAMES = 100;
  const READ_NODES = 250000;
  const READ_SIZE = 2000000;
  // `maxSize` lowers the characters (tabs.content splits its budget).
  function markdownBudget(maxSize) {
    const size = maxSize > 0 ? Math.min(READ_SIZE, Math.floor(maxSize)) : READ_SIZE;
    return { left: READ_NODES, sizeLeft: size, size, frames: MARKDOWN_FRAMES, cut: null };
  }
  function noteCut(budget, cut) {
    if (!budget.cut) budget.cut = cut;
  }

  async function frameMarkdown(page, frame, opts, depth, budget) {
    const r = await agentCall(frame, markdownOfFrame, { ...opts, maxNodes: Math.max(1, budget.left), maxSize: Math.max(1, budget.sizeLeft), maxFrames: budget.frames });
    const report = r.report || {};
    budget.left -= Math.max(0, Number(report.visited) || 0);
    budget.sizeLeft -= Math.max(0, Number(report.size) || 0);
    budget.frames -= r.frames.length;
    if (report.truncated) noteCut(budget, { truncated: report.truncated, maxNodes: READ_NODES, maxSize: budget.size });
    if (r.framesCut) noteCut(budget, { truncated: "frames", frames: MARKDOWN_FRAMES });
    if (r.nestCut) budget.nestCut = true;
    const text = r.blocks.join("\n\n");
    // Page text keeps no NUL, so only the agent's placeholders have one.
    const pageText = (s) => s.replace(/\u0000/g, "\uFFFD");
    if (!r.frames.length) return pageText(text);
    let children = null;
    try {
      const found = await page._session.call("frame.contentFrames", { targetId: page._targetId, frameId: frame._id || undefined, elements: r.frames });
      children = found.map((f) => (f ? page._frameFor(f.frameId, frame) : null));
    } catch (e) {
      if (errCode(e) !== "unsupported") throw e;
      children = [];
      for (const h of r.frames) children.push(await frame._contentFrame(h).catch(() => null));
    }
    const parts = [];
    for (const child of children) {
      // Frames nested deeper than six are left out, as before the budget.
      if (!child || depth >= 6 || budget.left < 1 || budget.sizeLeft < 1) {
        if (child && depth < 6) noteCut(budget, { truncated: budget.left < 1 ? "nodes" : "size", maxNodes: READ_NODES, maxSize: budget.size });
        parts.push("");
        continue;
      }
      parts.push(await frameMarkdown(page, child, { ...opts, main: false }, depth + 1, budget).catch(() => ""));
    }
    const placeholder = new RegExp(`\u0000F${String(r.mark).replace(/[^0-9a-z]/g, "")}:(\\d+)\u0000`, "g");
    let out = "";
    let last = 0;
    for (const m of text.matchAll(placeholder)) {
      out += pageText(text.slice(last, m.index)) + (parts[Number(m[1])] || "");
      last = m.index + m[0].length;
    }
    out += pageText(text.slice(last));
    return out.replace(/\n{3,}/g, "\n\n").trim();
  }

  // The page as Markdown: headings, paragraphs, lists, tables, code, links,
  // form values (never passwords), iframes and shadow roots in place.
  // { main: true } keeps the main content (<main>, the one <article>, else
  // the page without navigation, banner, footer and sidebars). { links: false }
  // drops link URLs, { images: true } keeps images. { start, maxChars } cut at
  // block boundaries; a cut says where to continue.
  P.markdown = async function (options = {}) {
    if (options === null || typeof options !== "object") throw new Error(`page.markdown: options: expected an object, got ${JSON.stringify(options)}`);
    const opts = { main: !!options.main, links: options.links !== false, images: !!options.images };
    await this._syncInfo().catch(() => {});
    const budget = markdownBudget(options._maxSize);
    let full = (await frameMarkdown(this, this._mainFrame, opts, 0, budget)) + "\n";
    // A page past the page-read budget ends with a note where it stopped.
    if (budget.cut) full += `\n<!-- ${core.readCutNote("Markdown", budget.cut)}; the rest of the page is not shown -->\n`;
    // Parts nested deeper than the walk reads (markdownOfFrame MAX_NEST)
    // are left out where they are; the rest of the page is read.
    if (budget.nestCut) full += "\n<!-- not read: parts of the page nested deeper than 1000 elements -->\n";
    const start = options.start || 0;
    const max = options.maxChars === undefined ? Infinity : options.maxChars;
    if (!Number.isInteger(start) || start < 0) throw new Error(`page.markdown: start: expected a non-negative integer, got ${JSON.stringify(options.start)}`);
    if (!(max > 0)) throw new Error(`page.markdown: maxChars: expected a positive number, got ${JSON.stringify(options.maxChars)}`);
    if (start === 0 && full.length <= max) return full;
    if (start >= full.length) throw new Error(`page.markdown: start ${start} is past the end (${full.length} characters)`);
    let end = Math.min(full.length, start + max);
    if (end < full.length) {
      const cut = full.lastIndexOf("\n\n", end);
      const line = full.lastIndexOf("\n", end);
      end = cut > start ? cut + 2 : line > start ? line + 1 : end;
    }
    let text = full.slice(start, end);
    // A cut inside a table repeats its header row.
    const before = full.slice(0, start);
    const tableStart = before.lastIndexOf("\n\n") + 2;
    if (start > 0 && /^\|/.test(text) && /^\|/.test(full.slice(tableStart))) {
      const header = full.slice(tableStart).split("\n").slice(0, 2);
      if (header.length === 2 && /^\|( --- \|)+$/.test(header[1]) && full.slice(tableStart, start).includes("\n")) text = header.join("\n") + "\n" + text;
    }
    const commas = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    const tail = end < full.length ? `; continue with page.markdown({ start: ${end}${options.maxChars !== undefined ? `, maxChars: ${options.maxChars}` : ""}${options.main ? ", main: true" : ""} })` : "";
    return text.replace(/\n*$/, "\n") + `\n<!-- characters ${commas(start)} to ${commas(end)} of ${commas(full.length)}${tail} -->\n`;
  };

  // Structured data by selectors, no model: page.extract({ $: ".product",
  // name: "h3", price: ".price", url: "a@href" }). { scope: ref | locator }
  // limits it to one element; { limit } caps each list (1000).
  P.extract = async function (schema, options = {}) {
    let frame = this._mainFrame;
    let scope = null;
    if (options.scope) {
      const loc = typeof options.scope === "string" ? this.locator(options.scope) : options.scope;
      if (!(loc instanceof core.Locator)) throw new Error("page.extract: scope: expected a ref, selector or locator");
      const r = await loc._resolveOne(true);
      if (!r) throw new Error(`page.extract: scope ${loc} matched nothing`);
      frame = r.frame;
      scope = r.handle;
    }
    const unpair = (v) => {
      if (Array.isArray(v)) return v.map(unpair);
      if (v && typeof v === "object" && Array.isArray(v.__cmuxPairs)) {
        const o = {};
        for (const [k, x] of v.__cmuxPairs) o[k] = unpair(x);
        return o;
      }
      return v;
    };
    const pair = (v) => {
      if (Array.isArray(v)) return v.map(pair);
      if (v && typeof v === "object") return { __cmuxPairs: Object.entries(v).map(([k, x]) => [k, pair(x)]) };
      return v;
    };
    const r = await agentCall(frame, extractInFrame, pair(schema), { scope, limit: options.limit });
    if (r.report && r.report.truncated) printCut(this, "page.extract", r.report, "the values after it are null or left out");
    return unpair(r.value);
  };

  // Text matches with surrounding context and the ref of the element each is
  // in: { total, matches: [{ match, context, ref }] }.
  P.searchText = async function (pattern, options = {}) {
    if (typeof pattern !== "string" || !pattern) throw new Error(`page.searchText: pattern: expected a non-empty string, got ${JSON.stringify(pattern)}`);
    let frame = this._mainFrame;
    let scope = null;
    if (options.scope) {
      const loc = typeof options.scope === "string" ? this.locator(options.scope) : options.scope;
      const r = await loc._resolveOne(true);
      if (!r) throw new Error(`page.searchText: scope ${loc} matched nothing`);
      frame = r.frame;
      scope = r.handle;
    }
    const r = await agentCall(frame, searchTextInFrame, { pattern, regex: !!options.regex, caseSensitive: !!options.caseSensitive, context: options.context === undefined ? 60 : options.context, limit: options.limit === undefined ? 25 : options.limit, scope });
    if (r.report) printCut(this, "page.searchText", r.report, "matches after it are not counted or returned");
    const matches = [];
    for (const m of r.matches) {
      let ref = null;
      if (m.handle) ref = await this._refForHandle(frame, m.handle).catch(() => null);
      matches.push({ match: m.match, context: m.context, ref });
    }
    return { total: r.total, matches };
  };

  const targetLocator = (page, target, title) => {
    if (typeof target === "string") return page.locator(target);
    if (target instanceof core.Locator) return target;
    throw new Error(`${title}: expected a ref, selector or locator, got ${JSON.stringify(target)}`);
  };

  // Scrolls the first element with this text into view; returns its ref.
  P.scrollToText = async function (text, options = {}) {
    if (typeof text !== "string" || !text) throw new Error(`page.scrollToText: text: expected a non-empty string, got ${JSON.stringify(text)}`);
    const loc = this.getByText(text, { exact: !!options.exact }).first();
    await loc.scrollIntoViewIfNeeded({ timeout: options.timeout === undefined ? 5000 : options.timeout });
    const r = await loc._resolveOne(false);
    return r ? this._refForHandle(r.frame, r.handle) : null;
  };

  // Where the page, or a scrollable element, is scrolled:
  // { x, y, viewportHeight, scrollHeight, pagesAbove, pagesBelow }.
  P.scrollInfo = async function (target) {
    if (target === undefined) return agentCall(this._mainFrame, scrollInfoInFrame, null);
    const r = await targetLocator(this, target, "page.scrollInfo")._resolveOne(true);
    if (!r) throw new Error(`page.scrollInfo: ${target} matched nothing`);
    return agentCall(r.frame, scrollInfoInFrame, r.handle);
  };

  // Scrolls by pages with real wheel events, over the page or an element
  // (negative pages scroll up); returns scrollInfo afterwards.
  P.scroll = async function (options = {}) {
    const pages = options.pages === undefined ? 1 : options.pages;
    if (typeof pages !== "number" || !Number.isFinite(pages) || pages === 0) throw new Error(`page.scroll: pages: expected a non-zero number, got ${JSON.stringify(options.pages)}`);
    let point;
    let info;
    if (options.target !== undefined) {
      const loc = targetLocator(this, options.target, "page.scroll");
      await loc.scrollIntoViewIfNeeded();
      const box = await loc.boundingBox();
      if (!box) throw new Error(`page.scroll: ${options.target} is not visible`);
      point = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
      info = await this.scrollInfo(options.target);
    } else {
      info = await this.scrollInfo();
      const vp = await this._mainFrame._call("agent", "() => ({ w: innerWidth, h: innerHeight })", []);
      point = { x: vp.w / 2, y: vp.h / 2 };
    }
    // A scroll position set by script (scrollIntoView, scrollToText) reaches
    // WebKit's scrolling tree at the next rendering update; a wheel sent
    // before it starts from the old position and is dropped.
    await this._mainFrame._call("agent", "() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))", []);
    await this.mouse.move(point.x, point.y);
    await this.mouse.wheel(0, Math.round(pages * info.viewportHeight));
    let last = null;
    for (let i = 0; i < 20; i++) {
      const now = options.target !== undefined ? await this.scrollInfo(options.target) : await this.scrollInfo();
      if (last && now.y === last.y && now.y !== info.y) return now;
      last = now;
      await this._session.sleep(50);
    }
    return last;
  };

  // The options of a native <select> or an ARIA combobox, listbox or menu:
  // [{ index, label, value, selected, disabled, ref? }]. An ARIA popup must
  // be open (its options in the page).
  P.dropdownOptions = async function (target) {
    const r = await targetLocator(this, target, "page.dropdownOptions")._resolveOne(true);
    if (!r) throw new Error(`page.dropdownOptions: ${target} matched nothing`);
    const d = await agentCall(r.frame, dropdownInFrame, r.handle);
    if (d.kind === "none") throw new Error(`page.dropdownOptions: ${target} is not a <select> and controls no listbox or menu; open the drop-down first, then pass it or its listbox`);
    if (d.kind === "aria" && !d.options.length) throw new Error(`page.dropdownOptions: the listbox of ${target} shows no options; click it to open it, then call again`);
    const out = [];
    for (const o of d.options) {
      const row = { index: o.index, label: o.label, value: o.value, selected: o.selected, disabled: o.disabled };
      if (o.handle) row.ref = await this._refForHandle(r.frame, o.handle).catch(() => null);
      out.push(row);
    }
    if (d.report && d.report.truncated) printCut(this, "page.dropdownOptions", d.report, "the options after it are not listed");
    return out;
  };

  // Boxes and ref labels over elements, until hideHighlight() or the next
  // highlight: every interactive element without targets (reference C's
  // highlight_elements), else the given refs or locators. Returns the count.
  P.highlight = async function (targets) {
    await this.hideHighlight();
    if (targets === undefined) {
      this._highlightClear = await ns.snapshot.annotate(this);
      return null;
    }
    const byFrame = new Map();
    for (const t of [].concat(targets)) {
      const r = await targetLocator(this, t, "page.highlight")._resolveAll();
      if (!r) continue;
      for (const h of r.handles) {
        const ref = await this._refForHandle(r.frame, h);
        const local = ref.replace(/^f\d+/, "");
        // Labels go only to the document that issued the refs
        // (page-agent.js annotate): a ref of another document is left out.
        const doc = this._refDocFor(r.frame, local);
        if (!byFrame.has(r.frame)) byFrame.set(r.frame, { doc, pairs: [] });
        const entry = byFrame.get(r.frame);
        if (entry.doc === doc) entry.pairs.push([local, ref]);
      }
    }
    let n = 0;
    for (const [frame, { doc, pairs }] of byFrame) n += await frame._agent("annotate", pairs, doc);
    const frames = [...byFrame.keys()];
    this._highlightClear = async () => {
      for (const f of frames) await f._agent("clearAnnotations").catch(() => {});
    };
    return n;
  };
  P.hideHighlight = async function () {
    const clear = this._highlightClear;
    this._highlightClear = null;
    if (clear) await clear();
  };
  core.Locator.prototype.highlight = async function () {
    await this._page.highlight(this);
  };

  // Playwright's context.storageState / setStorageState names.
  const context = P.context;
  P.context = function () {
    const c = context.call(this);
    const storage = this._session.agentStorage;
    // Scoped like session.storageState, to this page's site.
    if (storage) Object.assign(c, { storageState: (options = {}) => storage.storageState(options, this), setStorageState: (source) => storage.setStorageState(source, this) });
    return c;
  };

  ns.agentTools = { install, urlMatches, parsePattern, normalizeHost, policyContentRules, isIPHost, totp, base32Decode, sha1, crc32, buildApng, pngChunks, parseResults, markdownOfFrame };
})(typeof globalThis !== "undefined" ? globalThis : this);
