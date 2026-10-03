// cmux browser REPL runtime core.
//
// A Playwright-like object model (Page, Frame, Locator, Keyboard, Mouse, ...)
// built on the engine driver protocol (docs/browser-repl/driver-protocol.md).
// Engine-neutral: runs in JavaScriptCore inside the app and in Node for the
// parity suite. Host capabilities (timers, console, fs, fetch) arrive through
// an injected `host` object; nothing here imports Node built-ins.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  // Playwright's selector builders, with the text argument checked first:
  // getByText(42) fails as an invalid argument instead of matching nothing.
  const LU = (() => {
    const raw = ns.locatorUtils;
    const textArg = (title, v) => {
      if (typeof v !== "string" && Object.prototype.toString.call(v) !== "[object RegExp]") {
        throw new Error(`${title}: text: expected a string or a RegExp, got ${JSON.stringify(v)}`);
      }
    };
    const wrapped = Object.create(raw);
    for (const [name, title] of [["getByTextSelector", "getByText"], ["getByLabelSelector", "getByLabel"], ["getByPlaceholderSelector", "getByPlaceholder"], ["getByAltTextSelector", "getByAltText"], ["getByTitleSelector", "getByTitle"]]) {
      wrapped[name] = (text, options) => (textArg(title, text), raw[name](text, options));
    }
    wrapped.getByTestIdSelector = (attr, testId) => (textArg("getByTestId", testId), raw.getByTestIdSelector(attr, testId));
    wrapped.getByRoleSelector = (role, options) => {
      if (typeof role !== "string" || !role) throw new Error(`getByRole: role: expected a non-empty string, got ${JSON.stringify(role)}`);
      return raw.getByRoleSelector(role, options);
    };
    return wrapped;
  })();
  const AGENT = 'globalThis[Symbol.for("cmux.browserRepl.agent")]';
  const DEFAULT_TIMEOUT = 30000;
  const UNDEFINED_MARK = "__cmuxUndefined__";

  // ---------------------------------------------------------------------------
  // Errors

  class TimeoutError extends Error {
    constructor(message) {
      super(message);
      this.name = "TimeoutError";
    }
  }
  class StaleRefError extends Error {
    constructor(message) {
      super(message);
      this.name = "Error";
    }
  }
  // Snapshot refs: "e5" in the main frame, "f2e5" in the frame with prefix f2.
  const REF_PATTERN = /^(f\d+)?(e\d+)$/;

  function driverErrorCode(e) {
    return e && e.code;
  }

  // ---------------------------------------------------------------------------
  // Minimal Buffer. JavaScriptCore has neither Buffer, TextEncoder nor atob,
  // so the byte helpers are implemented here once for both engines.

  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const B64_LOOKUP = (() => {
    const t = new Int16Array(256).fill(-1);
    for (let i = 0; i < B64.length; i++) t[B64.charCodeAt(i)] = i;
    t["-".charCodeAt(0)] = 62;
    t["_".charCodeAt(0)] = 63;
    return t;
  })();

  function utf8Encode(str) {
    const out = [];
    for (let i = 0; i < str.length; i++) {
      let c = str.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        const d = str.charCodeAt(i + 1);
        if (d >= 0xdc00 && d <= 0xdfff) {
          c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
          i++;
        } else c = 0xfffd;
      } else if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return out;
  }

  function utf8Decode(bytes, start = 0, end = bytes.length) {
    let out = "";
    let i = start;
    while (i < end) {
      const b = bytes[i];
      let c;
      let n = 0;
      if (b < 0x80) c = b;
      else if (b >= 0xc2 && b < 0xe0) (c = b & 31), (n = 1);
      else if (b >= 0xe0 && b < 0xf0) (c = b & 15), (n = 2);
      else if (b >= 0xf0 && b < 0xf5) (c = b & 7), (n = 3);
      else {
        out += "�";
        i++;
        continue;
      }
      if (i + n >= end + (n ? 0 : 1) && n) {
        out += "�";
        break;
      }
      let ok = true;
      for (let k = 1; k <= n; k++) {
        const cb = bytes[i + k];
        if ((cb & 0xc0) !== 0x80) {
          ok = false;
          break;
        }
        c = (c << 6) | (cb & 63);
      }
      if (!ok) {
        out += "�";
        i++;
        continue;
      }
      i += n + 1;
      if (c >= 0x10000) {
        c -= 0x10000;
        out += String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 1023));
      } else out += String.fromCharCode(c);
    }
    return out;
  }

  function base64Encode(bytes) {
    let out = "";
    let i = 0;
    for (; i + 2 < bytes.length; i += 3) {
      const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += B64[n >> 18] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
    }
    if (i < bytes.length) {
      const n = (bytes[i] << 16) | ((i + 1 < bytes.length ? bytes[i + 1] : 0) << 8);
      out += B64[n >> 18] + B64[(n >> 12) & 63] + (i + 1 < bytes.length ? B64[(n >> 6) & 63] : "=") + "=";
    }
    return out;
  }

  function base64Decode(str) {
    const clean = String(str).replace(/[^A-Za-z0-9+/\-_]/g, "");
    const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
    let bits = 0;
    let acc = 0;
    let j = 0;
    for (let i = 0; i < clean.length; i++) {
      acc = (acc << 6) | B64_LOOKUP[clean.charCodeAt(i)];
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out[j++] = (acc >> bits) & 255;
      }
    }
    return out.subarray(0, j);
  }

  class Buffer extends Uint8Array {
    static from(value, encodingOrOffset, length) {
      if (typeof value === "string") {
        const enc = (encodingOrOffset || "utf8").toLowerCase();
        if (enc === "base64" || enc === "base64url") return Buffer._wrap(base64Decode(value));
        if (enc === "hex") {
          const out = new Buffer(Math.floor(value.length / 2));
          for (let i = 0; i < out.length; i++) out[i] = parseInt(value.substr(i * 2, 2), 16);
          return out;
        }
        if (enc === "latin1" || enc === "binary" || enc === "ascii") {
          const out = new Buffer(value.length);
          for (let i = 0; i < value.length; i++) out[i] = value.charCodeAt(i) & 255;
          return out;
        }
        return Buffer._wrap(utf8Encode(value));
      }
      if (value instanceof ArrayBuffer) {
        return new Buffer(value, encodingOrOffset || 0, length === undefined ? value.byteLength - (encodingOrOffset || 0) : length);
      }
      if (ArrayBuffer.isView(value)) {
        return Buffer._wrap(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
      }
      if (value && value.type === "Buffer" && Array.isArray(value.data)) return Buffer._wrap(value.data);
      return Buffer._wrap(value);
    }
    static _wrap(bytes) {
      const out = new Buffer(bytes.length);
      out.set(bytes);
      return out;
    }
    static alloc(size, fill) {
      const out = new Buffer(size);
      if (fill !== undefined) out.fill(typeof fill === "string" ? fill.charCodeAt(0) : fill);
      return out;
    }
    static isBuffer(value) {
      return value instanceof Buffer || !!(root.Buffer && root.Buffer !== Buffer && root.Buffer.isBuffer && root.Buffer.isBuffer(value));
    }
    static byteLength(value, encoding) {
      return typeof value === "string" ? Buffer.from(value, encoding).length : value.byteLength;
    }
    static concat(list, total) {
      const size = total === undefined ? list.reduce((n, b) => n + b.length, 0) : total;
      const out = new Buffer(size);
      let offset = 0;
      for (const b of list) {
        out.set(b.subarray(0, Math.max(0, size - offset)), offset);
        offset += b.length;
        if (offset >= size) break;
      }
      return out;
    }
    toString(encoding, start = 0, end = this.length) {
      const enc = (encoding || "utf8").toLowerCase();
      const view = this.subarray(start, end);
      if (enc === "base64") return base64Encode(view);
      if (enc === "base64url") return base64Encode(view).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
      if (enc === "hex") return Array.from(view, (b) => b.toString(16).padStart(2, "0")).join("");
      if (enc === "latin1" || enc === "binary" || enc === "ascii") {
        let s = "";
        for (const b of view) s += String.fromCharCode(enc === "ascii" ? b & 127 : b);
        return s;
      }
      return utf8Decode(view);
    }
    toJSON() {
      return { type: "Buffer", data: Array.from(this) };
    }
    equals(other) {
      if (other.length !== this.length) return false;
      for (let i = 0; i < this.length; i++) if (this[i] !== other[i]) return false;
      return true;
    }
    slice(start, end) {
      return this.subarray(start, end);
    }
    write(string, offset = 0, encoding) {
      const bytes = Buffer.from(string, encoding);
      this.set(bytes.subarray(0, this.length - offset), offset);
      return Math.min(bytes.length, this.length - offset);
    }
  }

  // ---------------------------------------------------------------------------
  // URL fallback. A bare JSContext has no URL/URLSearchParams; this covers the
  // WHATWG behaviors the runtime relies on (special-scheme parsing, default
  // ports, dot segments, relative resolution, form-encoded query edits with a
  // live key iterator). Engines that ship URL use their own.

  const DEFAULT_PORTS = { "http:": "80", "https:": "443", "ws:": "80", "wss:": "443", "ftp:": "21", "file:": "" };

  function formEncode(s) {
    return utf8Encode(String(s)).map((b) => {
      const c = String.fromCharCode(b);
      if (/[A-Za-z0-9*\-._]/.test(c)) return c;
      if (b === 0x20) return "+";
      return "%" + b.toString(16).toUpperCase().padStart(2, "0");
    }).join("");
  }
  function formDecode(s) {
    const bytes = [];
    const str = s.replace(/\+/g, " ");
    for (let i = 0; i < str.length; i++) {
      if (str[i] === "%" && /^[0-9a-fA-F]{2}$/.test(str.substr(i + 1, 2))) {
        bytes.push(parseInt(str.substr(i + 1, 2), 16));
        i += 2;
      } else bytes.push(...utf8Encode(str[i]));
    }
    return utf8Decode(bytes);
  }

  class MiniURLSearchParams {
    constructor(init) {
      this._list = [];
      this._url = null;
      if (typeof init === "string") {
        for (const part of init.replace(/^\?/, "").split("&")) {
          if (!part) continue;
          const i = part.indexOf("=");
          this._list.push(i < 0 ? [formDecode(part), ""] : [formDecode(part.slice(0, i)), formDecode(part.slice(i + 1))]);
        }
      } else if (init && typeof init === "object") {
        for (const [k, v] of Array.isArray(init) ? init : Object.entries(init)) this._list.push([String(k), String(v)]);
      }
    }
    _update() {
      if (this._url) this._url._search = this._list.length ? "?" + this.toString() : "";
    }
    get(k) {
      const e = this._list.find((x) => x[0] === k);
      return e ? e[1] : null;
    }
    getAll(k) {
      return this._list.filter((x) => x[0] === k).map((x) => x[1]);
    }
    has(k) {
      return this._list.some((x) => x[0] === k);
    }
    append(k, v) {
      this._list.push([String(k), String(v)]);
      this._update();
    }
    set(k, v) {
      const i = this._list.findIndex((x) => x[0] === k);
      if (i < 0) this._list.push([String(k), String(v)]);
      else {
        this._list[i][1] = String(v);
        this._list = this._list.filter((x, j) => j <= i || x[0] !== k);
      }
      this._update();
    }
    delete(k) {
      this._list = this._list.filter((x) => x[0] !== k);
      this._update();
    }
    _iter(map) {
      let i = 0;
      const self = this;
      return {
        next: () => (i < self._list.length ? { value: map(self._list[i++]), done: false } : { value: undefined, done: true }),
        [Symbol.iterator]() {
          return this;
        },
      };
    }
    keys() {
      return this._iter((e) => e[0]);
    }
    values() {
      return this._iter((e) => e[1]);
    }
    entries() {
      return this._iter((e) => [e[0], e[1]]);
    }
    [Symbol.iterator]() {
      return this.entries();
    }
    forEach(fn) {
      for (const [k, v] of this._list) fn(v, k, this);
    }
    toString() {
      return this._list.map(([k, v]) => `${formEncode(k)}=${formEncode(v)}`).join("&");
    }
  }

  function removeDotSegments(p) {
    const out = [];
    const segs = p.split("/");
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      if (s === "..") {
        if (out.length > 1) out.pop();
        if (i === segs.length - 1) out.push("");
      } else if (s === ".") {
        if (i === segs.length - 1) out.push("");
      } else out.push(s);
    }
    const joined = out.join("/");
    return joined.startsWith("/") ? joined : "/" + joined;
  }

  // The userinfo percent-encode set of the URL standard.
  function encodeUserinfo(v) {
    return Array.from(String(v), (ch) => (/[A-Za-z0-9\-._~!$&'()*+,;=]/.test(ch) ? ch : encodeURIComponent(ch))).join("").replace(/%25([0-9A-Fa-f]{2})/g, "%$1");
  }

  class MiniURL {
    constructor(input, base) {
      input = String(input).trim();
      const m = /^([a-zA-Z][a-zA-Z0-9+.\-]*):(.*)$/.exec(input);
      if (m) this._parseAbsolute(m[1].toLowerCase() + ":", m[2]);
      else if (base !== undefined) this._resolve(input, base instanceof MiniURL ? base : new MiniURL(String(base)));
      else throw new TypeError(`Invalid URL: ${input}`);
    }
    _parseAbsolute(protocol, rest) {
      this._protocol = protocol;
      this._username = this._password = this._hostname = this._port = "";
      this._search = this._hash = "";
      const special = protocol in DEFAULT_PORTS;
      if (!special) {
        const h = rest.indexOf("#");
        if (h >= 0) (this._hash = rest.slice(h)), (rest = rest.slice(0, h));
        const q = rest.indexOf("?");
        if (q >= 0) (this._search = rest.slice(q)), (rest = rest.slice(0, q));
        this._pathname = rest;
        this._opaque = true;
        return;
      }
      rest = rest.replace(/\\/g, "/").replace(/^\/*/, "");
      const h = rest.indexOf("#");
      if (h >= 0) (this._hash = rest.slice(h)), (rest = rest.slice(0, h));
      const q = rest.indexOf("?");
      if (q >= 0) (this._search = rest.slice(q)), (rest = rest.slice(0, q));
      const slash = rest.indexOf("/");
      let authority = slash >= 0 ? rest.slice(0, slash) : rest;
      const path = slash >= 0 ? rest.slice(slash) : "/";
      const at = authority.lastIndexOf("@");
      if (at >= 0) {
        const cred = authority.slice(0, at);
        authority = authority.slice(at + 1);
        const c = cred.indexOf(":");
        this._username = c >= 0 ? cred.slice(0, c) : cred;
        this._password = c >= 0 ? cred.slice(c + 1) : "";
      }
      const pm = /^(\[[^\]]*\]|[^:]*)(?::(\d*))?$/.exec(authority);
      if (!pm || (!pm[1] && protocol !== "file:")) throw new TypeError(`Invalid URL: ${protocol}${rest}`);
      this._hostname = pm[1].toLowerCase();
      this._port = pm[2] && pm[2] !== DEFAULT_PORTS[protocol] ? String(Number(pm[2])) : "";
      this._pathname = removeDotSegments(path);
      this._opaque = false;
    }
    _resolve(input, base) {
      if (base._opaque) throw new TypeError(`Invalid URL: ${input}`);
      if (input.startsWith("//")) return this._parseAbsolute(base._protocol, input);
      Object.assign(this, { _protocol: base._protocol, _username: base._username, _password: base._password, _hostname: base._hostname, _port: base._port, _opaque: false });
      let rest = input;
      let hash = "";
      const h = rest.indexOf("#");
      if (h >= 0) (hash = rest.slice(h)), (rest = rest.slice(0, h));
      let search = null;
      const q = rest.indexOf("?");
      if (q >= 0) (search = rest.slice(q)), (rest = rest.slice(0, q));
      if (!rest) {
        this._pathname = base._pathname;
        this._search = search !== null ? search : base._search;
      } else {
        const merged = rest.startsWith("/") ? rest : base._pathname.replace(/[^/]*$/, "") + rest;
        this._pathname = removeDotSegments(merged);
        this._search = search !== null ? search : "";
      }
      this._hash = hash;
    }
    get protocol() {
      return this._protocol;
    }
    get hostname() {
      return this._hostname;
    }
    get port() {
      return this._port;
    }
    get host() {
      return this._hostname + (this._port ? ":" + this._port : "");
    }
    get origin() {
      return this._opaque || this._protocol === "file:" ? "null" : `${this._protocol}//${this.host}`;
    }
    get pathname() {
      return this._pathname;
    }
    get search() {
      return this._search === "?" ? "" : this._search;
    }
    set search(v) {
      v = String(v);
      this._search = v ? (v.startsWith("?") ? v : "?" + v) : "";
      this._params = null;
    }
    get hash() {
      return this._hash === "#" ? "" : this._hash;
    }
    // Setters as in WHATWG URL for the common parts (credentials above all:
    // `u.username = "a"; page.goto(u.href)` signs in to HTTP auth).
    get username() {
      return this._username;
    }
    set username(v) {
      if (this._opaque || !this._hostname) return;
      this._username = encodeUserinfo(v);
    }
    get password() {
      return this._password;
    }
    set password(v) {
      if (this._opaque || !this._hostname) return;
      this._password = encodeUserinfo(v);
    }
    set hash(v) {
      v = String(v);
      this._hash = v ? (v.startsWith("#") ? v : "#" + v) : "";
    }
    set pathname(v) {
      if (this._opaque) return;
      v = String(v);
      this._pathname = removeDotSegments(v.startsWith("/") ? v : "/" + v);
    }
    set hostname(v) {
      if (this._opaque) return;
      this._hostname = String(v).toLowerCase();
    }
    set port(v) {
      if (this._opaque) return;
      v = String(v);
      if (v === "" || v === DEFAULT_PORTS[this._protocol]) this._port = "";
      else if (/^\d+$/.test(v)) this._port = String(Number(v));
    }
    set host(v) {
      const m = /^(\[[^\]]*\]|[^:]*)(?::(\d*))?$/.exec(String(v));
      if (!m || this._opaque) return;
      this.hostname = m[1];
      if (m[2] !== undefined) this.port = m[2];
    }
    set href(v) {
      const next = new MiniURL(String(v));
      Object.assign(this, next);
      this._params = null;
    }
    get searchParams() {
      if (!this._params) {
        this._params = new MiniURLSearchParams(this._search);
        this._params._url = this;
      }
      return this._params;
    }
    get href() {
      if (this._opaque) return this._protocol + this._pathname + this._search + this._hash;
      const cred = this._username || this._password ? this._username + (this._password ? ":" + this._password : "") + "@" : "";
      return `${this._protocol}//${cred}${this.host}${this._pathname}${this._search}${this._hash}`;
    }
    toString() {
      return this.href;
    }
    toJSON() {
      return this.href;
    }
  }

  const URLImpl = typeof root.URL === "function" ? root.URL : MiniURL;
  const URLSearchParamsImpl = typeof root.URLSearchParams === "function" ? root.URLSearchParams : MiniURLSearchParams;

  // ---------------------------------------------------------------------------
  // Events

  // Page events whose listeners a session reports to the driver.
  const HANDLED_EVENTS = ["dialog", "filechooser", "download"];
  // How long a call on a tab waits for that tab's pending tab.handleEvents.
  const HANDLED_SYNC_TIMEOUT = 5000;
  // What the bounded wait resolves with when the update did not settle.
  const HANDLED_SYNC_LATE = Symbol("handled sync late");
  // A key no listener set has: the next _syncHandledEvents always sends,
  // even an empty set (a lost update may have been the one removing the
  // last listener).
  const HANDLED_KEY_RESEND = Symbol("handled key resend");

  class EventEmitter {
    constructor() {
      this._listeners = new Map();
    }
    on(event, handler) {
      if (!this._listeners.has(event)) this._listeners.set(event, []);
      this._listeners.get(event).push({ handler, once: false });
      return this;
    }
    addListener(event, handler) {
      return this.on(event, handler);
    }
    once(event, handler) {
      if (!this._listeners.has(event)) this._listeners.set(event, []);
      this._listeners.get(event).push({ handler, once: true });
      return this;
    }
    off(event, handler) {
      const list = this._listeners.get(event);
      if (list) this._listeners.set(event, list.filter((l) => l.handler !== handler));
      return this;
    }
    removeListener(event, handler) {
      return this.off(event, handler);
    }
    removeAllListeners(event) {
      if (event === undefined) this._listeners.clear();
      else this._listeners.delete(event);
      return this;
    }
    listenerCount(event) {
      return (this._listeners.get(event) || []).length;
    }
    emit(event, ...args) {
      const list = this._listeners.get(event);
      if (!list || !list.length) return false;
      this._listeners.set(event, list.filter((l) => !l.once));
      for (const l of list) {
        try {
          const r = l.handler(...args);
          if (r && typeof r.catch === "function") r.catch((e) => this._reportListenerError(e));
        } catch (e) {
          this._reportListenerError(e);
        }
      }
      return true;
    }
    _reportListenerError(e) {
      if (this._session) this._session.reportError(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Keyboard layout (US), after Playwright's usKeyboardLayout.

  const KEYS = {};
  function defKey(key, code, keyCode, extra) {
    KEYS[key] = Object.assign({ key, code, keyCode }, extra || {});
  }
  (function buildLayout() {
    const named = [
      ["Escape", "Escape", 27], ["F1", "F1", 112], ["F2", "F2", 113], ["F3", "F3", 114], ["F4", "F4", 115],
      ["F5", "F5", 116], ["F6", "F6", 117], ["F7", "F7", 118], ["F8", "F8", 119], ["F9", "F9", 120],
      ["F10", "F10", 121], ["F11", "F11", 122], ["F12", "F12", 123], ["Backspace", "Backspace", 8],
      ["Tab", "Tab", 9], ["Enter", "Enter", 13, { text: "\r" }], ["Delete", "Delete", 46], ["Insert", "Insert", 45],
      ["Home", "Home", 36], ["End", "End", 35], ["PageUp", "PageUp", 33], ["PageDown", "PageDown", 34],
      ["ArrowLeft", "ArrowLeft", 37], ["ArrowUp", "ArrowUp", 38], ["ArrowRight", "ArrowRight", 39],
      ["ArrowDown", "ArrowDown", 40], ["CapsLock", "CapsLock", 20], ["ContextMenu", "ContextMenu", 93],
      ["Shift", "ShiftLeft", 16, { location: 1 }], ["Control", "ControlLeft", 17, { location: 1 }],
      ["Alt", "AltLeft", 18, { location: 1 }], ["Meta", "MetaLeft", 91, { location: 1 }],
    ];
    for (const [key, code, keyCode, extra] of named) defKey(key, code, keyCode, extra);
    for (let i = 0; i < 26; i++) {
      const lower = String.fromCharCode(97 + i);
      const upper = lower.toUpperCase();
      defKey(lower, "Key" + upper, 65 + i, { text: lower, shiftKey: upper });
      defKey(upper, "Key" + upper, 65 + i, { text: upper, shifted: true });
    }
    const digits = ")!@#$%^&*(";
    for (let i = 0; i < 10; i++) {
      defKey(String(i), "Digit" + i, 48 + i, { text: String(i), shiftKey: digits[i] });
      defKey(digits[i], "Digit" + i, 48 + i, { text: digits[i], shifted: true });
    }
    const punct = [
      [";", ":", "Semicolon", 186], ["=", "+", "Equal", 187], [",", "<", "Comma", 188], ["-", "_", "Minus", 189],
      [".", ">", "Period", 190], ["/", "?", "Slash", 191], ["`", "~", "Backquote", 192], ["[", "{", "BracketLeft", 219],
      ["\\", "|", "Backslash", 220], ["]", "}", "BracketRight", 221], ["'", '"', "Quote", 222],
    ];
    for (const [plain, shifted, code, keyCode] of punct) {
      defKey(plain, code, keyCode, { text: plain, shiftKey: shifted });
      defKey(shifted, code, keyCode, { text: shifted, shifted: true });
    }
    defKey(" ", "Space", 32, { text: " " });
    defKey("\n", "Enter", 13, { text: "\r", alias: "Enter" });
    defKey("\r", "Enter", 13, { text: "\r", alias: "Enter" });
    defKey("\t", "Tab", 9, { alias: "Tab" });
    // Code names ("KeyA", "Digit1", "Space", "ShiftLeft"...) resolve to their unshifted key.
    for (const def of Object.values(KEYS)) {
      if (!def.shifted && !KEYS[def.code]) KEYS[def.code] = def;
    }
    defKey("ShiftRight", "ShiftRight", 16, { location: 2, keyName: "Shift" });
    defKey("ControlRight", "ControlRight", 17, { location: 2, keyName: "Control" });
    defKey("AltRight", "AltRight", 18, { location: 2, keyName: "Alt" });
    defKey("MetaRight", "MetaRight", 92, { location: 2, keyName: "Meta" });
  })();

  const MODIFIERS = ["Alt", "Control", "Meta", "Shift"];

  // "Shift+KeyC" -> ["Shift", "KeyC"]; a trailing "+" is the plus key.
  // Modifier names for a pointer action: Playwright's four plus ControlOrMeta.
  function normalizeModifiers(list) {
    if (list === undefined || list === null) return [];
    if (!Array.isArray(list)) throw new Error("modifiers: expected an array of Alt, Control, ControlOrMeta, Meta, Shift");
    return list.map((m) => {
      if (m === "ControlOrMeta") return "Meta";
      if (!["Alt", "Control", "Meta", "Shift"].includes(m)) throw new Error(`modifiers: unknown modifier ${JSON.stringify(m)}; expected Alt, Control, ControlOrMeta, Meta or Shift`);
      return m;
    });
  }

  function splitKeyCombo(combo) {
    if (typeof combo !== "string" || !combo) throw new Error(`key: expected a non-empty string, got ${JSON.stringify(combo)}`);
    const keys = [];
    let building = "";
    for (const ch of combo) {
      if (ch === "+" && building) {
        keys.push(building);
        building = "";
      } else building += ch;
    }
    keys.push(building);
    return keys;
  }

  // Resolves a Playwright key name to a key description given the held
  // modifiers, following Playwright's keyboard rules.
  function describeKey(name, modifiers) {
    if (typeof name !== "string" || !name) throw new Error(`key: expected a non-empty string, got ${JSON.stringify(name)}`);
    // Playwright's ControlOrMeta is Meta on macOS.
    if (name === "ControlOrMeta") name = "Meta";
    const def = KEYS[name];
    if (!def) {
      if ([...name].length === 1) return { key: name, code: "", keyCode: 0, text: name, location: 0 };
      throw new Error(`Unknown key: "${name}"`);
    }
    const shift = modifiers.has("Shift");
    let key = def.keyName || (def.alias ? KEYS[def.alias].key : def.key);
    let text = def.text || "";
    if (shift && def.shiftKey) {
      key = def.shiftKey;
      text = KEYS[def.shiftKey].text;
    }
    // Held Control/Meta/Alt (anything beyond Shift) suppress text insertion.
    if (modifiers.size > 1 || (modifiers.size === 1 && !shift)) text = "";
    return { key, code: def.code, keyCode: def.keyCode, text, location: def.location || 0 };
  }

  // ---------------------------------------------------------------------------
  // Helpers

  function functionSource(fn) {
    if (typeof fn === "function") {
      const src = fn.toString();
      if (/^\s*(async\s+)?(function\b|\(|[\w$]+\s*=>|[\w$]+\s*\(\s*\)\s*=>)/.test(src) || /^\s*class\b/.test(src)) return src;
      // Method shorthand: `foo(a) { ... }`.
      return /^\s*async\s/.test(src) ? src.replace(/^\s*async\s+/, "async function ") : "function " + src;
    }
    if (typeof fn === "string") return `() => (0, eval)(${JSON.stringify(fn)})`;
    throw new Error("Expected a function or a string to evaluate");
  }

  function isRegExp(v) {
    return Object.prototype.toString.call(v) === "[object RegExp]";
  }

  function globToRegex(glob) {
    let re = "^";
    for (let i = 0; i < glob.length; i++) {
      const c = glob[i];
      if (c === "*") {
        if (glob[i + 1] === "*") {
          re += ".*";
          i++;
        } else re += "[^/]*";
      } else if (c === "?") re += ".";
      else if (c === "{") {
        const end = glob.indexOf("}", i);
        if (end > i) {
          re += "(" + glob.slice(i + 1, end).split(",").map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|") + ")";
          i = end;
        } else re += "\\{";
      } else re += c.replace(/[.*+?^${}()|[\]\\\/]/g, "\\$&");
    }
    return new RegExp(re + "$");
  }

  function urlMatches(baseURL, url, match) {
    if (match === undefined || match === "") return true;
    if (typeof match === "function") {
      let parsed = url;
      try {
        parsed = new URLImpl(url);
      } catch {}
      return !!match(parsed);
    }
    if (isRegExp(match)) return match.test(url);
    let pattern = String(match);
    if (!pattern.startsWith("*")) {
      try {
        pattern = new URLImpl(pattern, baseURL || undefined).href;
      } catch {}
    }
    if (!/[*?{]/.test(pattern)) return url === pattern;
    return globToRegex(pattern).test(url);
  }

  // ---------------------------------------------------------------------------
  // Session: routes driver events to pages and owns host services.

  class Session {
    constructor({ driver, host, files }) {
      this.driver = driver;
      this.host = host;
      this.files = files || null;
      this.pages = new Map();
      // Tabs that closed; calls on them fail like Playwright's closed page.
      this.closedTargets = new Set();
      this.defaultTimeout = DEFAULT_TIMEOUT;
      this.defaultNavigationTimeout = DEFAULT_TIMEOUT;
      this.errors = [];
      this._lazyCounter = 0;
      this._unsubscribe = [];
      // Hooks agent-tools.js installs (docs/browser-repl/reference-c-parity.md):
      // the domain policy, secret redaction, recording and secret input.
      this.agentTools = null;
      const route = (event, fn) => this._unsubscribe.push(driver.on(event, (payload) => {
        payload = payload || {};
        if (this.agentTools) payload = this.agentTools.onEvent(event, payload);
        fn(payload);
        if (this.agentTools) this.agentTools.afterEvent(event, payload);
      }));
      route("tab.created", (p) => this._onTabCreated(p));
      route("tab.closed", (p) => this._page(p.targetId, false) && this._page(p.targetId)._onClosed());
      route("tab.crashed", (p) => this._forward(p, "_onCrashed"));
      route("tab.navigated", (p) => this._forward(p, "_onNavigated"));
      route("tab.loadState", (p) => this._forward(p, "_onLoadState"));
      route("dialog.opened", (p) => this._forward(p, "_onDialog"));
      route("filechooser.opened", (p) => this._forward(p, "_onFileChooser"));
      route("download.started", (p) => this._forward(p, "_onDownload"));
      route("download.finished", (p) => this._forward(p, "_onDownloadFinished"));
      // The driver cancelled a navigation the domain policy blocks; agent-tools.js
      // logs it and fails the action that caused it.
      route("navigation.blocked", () => {});
      route("console", (p) => this._forward(p, "_onConsole"));
      route("pageerror", (p) => this._forward(p, "_onPageError"));
      for (const event of ["request", "response", "requestfailed", "requestfinished"]) {
        route(event, (p) => this._forward(p, "_onNetwork", event));
      }
    }
    // A lazy page has no tab until its first driver call opens one, so `page`
    // is usable the moment a session starts.
    async call(method, params) {
      if (params && typeof params.targetId === "string" && this.closedTargets.has(params.targetId)) {
        throw new Error(`${method}: Target page, context or browser has been closed`);
      }
      const crashed = params && typeof params.targetId === "string" && this.pages.get(params.targetId);
      if (crashed && crashed._handledSync) await this._awaitHandledSync(crashed);
      if (crashed && crashed._crashed) {
        // A crashed page answers only what starts a new web process.
        if (["tab.navigate", "tab.reload", "tab.history"].includes(method)) crashed._crashed = false;
        else if (!["tabs.close", "tab.info", "tabs.activate", "tab.bringToFront", "tab.keep"].includes(method)) throw new Error(`${method}: Target crashed; call page.reload() or page.goto() to load it again`);
      }
      if (params && typeof params.targetId === "string" && params.targetId.startsWith("lazy:")) {
        const page = this.pages.get(params.targetId);
        if (page) params = Object.assign({}, params, { targetId: await this._materialize(page) });
      }
      if (!this.agentTools) return this.driver.call(method, params);
      await this.agentTools.beforeCall(method, params);
      return this.agentTools.afterCall(method, params, this.driver.call(method, params));
    }
    // Waits for a tab's pending tab.handleEvents update, at most
    // HANDLED_SYNC_TIMEOUT: an update whose job was dropped (a cell
    // terminated by the app's watchdog mid-drain) never settles, and no call
    // on the tab may wait for it forever. The next listener change sends the
    // state again.
    async _awaitHandledSync(page) {
      const pending = page._handledSync;
      let timer;
      const late = new Promise((resolve) => (timer = this.host.setTimeout(() => resolve(HANDLED_SYNC_LATE), HANDLED_SYNC_TIMEOUT)));
      const r = await Promise.race([pending, late]);
      if (this.host.clearTimeout) this.host.clearTimeout(timer);
      if (r === HANDLED_SYNC_LATE && page._handledSync === pending) {
        page._handledSync = null;
        page._handledKey = HANDLED_KEY_RESEND;
        page._syncHandledEvents();
      }
    }
    // After a cell is cancelled (the app's timeout, maybe a terminated
    // script), promise jobs that were queued may never run; drop every tab's
    // pending update and send the listener state again.
    _resetPendingState() {
      for (const page of this.pages.values()) {
        if (!page._handledSync) continue;
        page._handledSync = null;
        page._handledKey = HANDLED_KEY_RESEND;
        page._syncHandledEvents();
      }
    }
    lazyPage() {
      const page = new Page(this, `lazy:${++this._lazyCounter}`);
      page._url = "about:blank";
      this.pages.set(page._targetId, page);
      return page;
    }
    _materialize(page) {
      if (!page._materializing) {
        page._materializing = this.driver.call("tabs.open", { background: false }).then(({ targetId }) => {
          this.pages.delete(page._targetId);
          page._targetId = targetId;
          this.pages.set(targetId, page);
          return targetId;
        });
      }
      return page._materializing;
    }
    sleep(ms) {
      return new Promise((resolve) => this.host.setTimeout(resolve, ms));
    }
    now() {
      return this.host.now ? this.host.now() : Date.now();
    }
    reportError(e) {
      this.errors.push(e);
      const text = String((e && e.stack) || e);
      // The native session masks registered secrets in everything printed.
      if (this.host.console && this.host.console.error) this.host.console.error(text);
    }
    _page(targetId, create = true) {
      let page = this.pages.get(targetId);
      if (!page && create) {
        page = new Page(this, targetId);
        this.pages.set(targetId, page);
      }
      return page;
    }
    pageFor(targetId) {
      return this._page(targetId);
    }
    _forward(payload, method, arg) {
      const page = this._page(payload.targetId, false);
      if (page) page[method](payload, arg);
    }
    _onTabCreated(p) {
      const page = this._page(p.targetId);
      if (p.url && !page._url) page._url = p.url;
      if (p.openerTargetId) {
        page._opener = this._page(p.openerTargetId, false) || null;
        if (page._opener) page._opener.emit("popup", page);
      }
      this.emitTabCreated(page, p);
    }
    emitTabCreated() {}
    async newPage(url, { background } = {}) {
      const { targetId } = await this.call("tabs.open", { url, background: !!background });
      const page = this._page(targetId);
      if (url) page._url = url;
      return page;
    }
    dispose() {
      for (const u of this._unsubscribe) if (typeof u === "function") u();
    }
  }

  // Polls `fn` until it returns { done: true, value }, with Playwright's
  // backoff. Driver errors with code "stale" (navigation) are retried.
  async function poll(session, timeout, description, fn) {
    const delays = [0, 20, 50, 100, 100, 500];
    const deadline = timeout ? session.now() + timeout : Infinity;
    let attempt = 0;
    let lastLog = "";
    for (;;) {
      try {
        // An attempt that does not answer (a page still loading, a busy main
        // thread) must not outlive the timeout; it is abandoned at the deadline.
        let timer;
        const expired = {};
        const r = deadline === Infinity
          ? await fn()
          : await Promise.race([fn(), new Promise((resolve) => (timer = session.host.setTimeout(() => resolve(expired), Math.max(0, deadline - session.now()))))]);
        if (timer !== undefined && session.host.clearTimeout) session.host.clearTimeout(timer);
        if (r === expired) lastLog = lastLog || "the page did not answer";
        else {
          if (r && r.done) return r.value;
          if (r && r.log) lastLog = r.log;
          if (r && r.now && session.now() < deadline) continue;
        }
      } catch (e) {
        if (!["stale", "not_found"].includes(driverErrorCode(e))) throw e;
        lastLog = e.message;
      }
      if (session.now() >= deadline) {
        throw new TimeoutError(`${description}: Timeout ${timeout}ms exceeded.${lastLog ? `\n  - ${lastLog}` : ""}`);
      }
      await session.sleep(Math.min(delays[Math.min(attempt++, delays.length - 1)], Math.max(0, deadline - session.now())));
    }
  }

  // ---------------------------------------------------------------------------
  // Frame

  class Frame {
    constructor(page, id, parent) {
      this._page = page;
      this._id = id;
      this._parent = parent || null;
      this._url = "";
      this._name = "";
      this._detached = false;
    }
    page() {
      return this._page;
    }
    get _session() {
      return this._page._session;
    }
    url() {
      return this === this._page._mainFrame ? this._page._url : this._url;
    }
    name() {
      return this._name;
    }
    parentFrame() {
      return this._parent;
    }
    childFrames() {
      return this._page.frames().filter((f) => f._parent === this);
    }
    isDetached() {
      return this._detached;
    }
    // Script cannot run while a JavaScript dialog is open, so calls fail fast
    // with the way out instead of hanging until the evaluation timeout.
    _call(world, source, args, handles) {
      const blocked = this._page._blockedError();
      if (blocked) return Promise.reject(blocked);
      return this._page._raceDialog(this._session.call("frame.evaluate", {
        targetId: this._page._targetId,
        frameId: this._id || undefined,
        world,
        source,
        args: args || [],
        handles: handles || [],
        awaitPromise: true,
      }), true);
    }
    // A user function in the page world. JSON has no undefined, so a function
    // that returns undefined sends a marker the result turns back into it,
    // as Playwright's evaluate returns undefined.
    async _evalPage(source, args, handles) {
      const wrapped = `async (...a) => { const v = await (${source})(...a); return v === undefined ? { ${JSON.stringify(UNDEFINED_MARK)}: 1 } : v; }`;
      const r = await this._call("page", wrapped, args, handles);
      return r && typeof r === "object" && !Array.isArray(r) && r[UNDEFINED_MARK] === 1 && Object.keys(r).length === 1 ? undefined : r;
    }
    _agent(method, ...args) {
      return this._call("agent", `(m, ...a) => ${AGENT}[m](...a)`, [method, ...args]);
    }
    async _contentFrame(handle) {
      try {
        const r = await this._session.call("frame.contentFrame", { targetId: this._page._targetId, frameId: this._id || undefined, element: handle });
        if (!r) return null;
        return this._page._frameFor(r.frameId, this);
      } catch (e) {
        if (driverErrorCode(e) !== "unsupported") throw e;
      }
      // Fallback for drivers without frame.contentFrame: match the iframe's
      // content box against each child frame's owner box.
      const box = await this._agent("contentBox", handle);
      await this._page._refreshFrames();
      for (const child of this.childFrames()) {
        const owner = await this._session.call("frame.ownerBox", { targetId: this._page._targetId, frameId: child._id });
        if (owner && Math.abs(owner.x - box.x) < 1 && Math.abs(owner.y - box.y) < 1 && Math.abs(owner.width - box.width) < 1) return child;
      }
      return null;
    }
    // Offset of this frame's viewport inside the tab viewport.
    async _viewportOffset() {
      if (!this._parent) return { x: 0, y: 0 };
      const box = await this._session.call("frame.ownerBox", { targetId: this._page._targetId, frameId: this._id });
      const parent = await this._parent._viewportOffset();
      return { x: parent.x + box.x, y: parent.y + box.y };
    }
    async evaluate(fn, arg) {
      return this._evalPage(functionSource(fn), [arg]);
    }
    async evaluateHandle(fn, arg) {
      return this.evaluate(fn, arg);
    }
    async content() {
      return this.evaluate(() => {
        let doctype = "";
        if (document.doctype) doctype = new XMLSerializer().serializeToString(document.doctype);
        return doctype + (document.documentElement ? document.documentElement.outerHTML : "");
      });
    }
    async title() {
      return this.evaluate(() => document.title);
    }
    locator(selector, options) {
      // Refs carry their frame, so a ref resolves from the page in any frame.
      if (this !== this._page._mainFrame && typeof selector === "string" && REF_PATTERN.test(selector.trim())) {
        return this._page.locator(selector, options);
      }
      return new Locator(this, this._page._normalizeSelector(selector), options);
    }
    getByRole(role, options) {
      return this.locator(LU.getByRoleSelector(role, options));
    }
    getByText(text, options) {
      return this.locator(LU.getByTextSelector(text, options));
    }
    getByLabel(text, options) {
      return this.locator(LU.getByLabelSelector(text, options));
    }
    getByPlaceholder(text, options) {
      return this.locator(LU.getByPlaceholderSelector(text, options));
    }
    getByAltText(text, options) {
      return this.locator(LU.getByAltTextSelector(text, options));
    }
    getByTitle(text, options) {
      return this.locator(LU.getByTitleSelector(text, options));
    }
    getByTestId(testId) {
      return this.locator(LU.getByTestIdSelector(this._page._testIdAttribute, testId));
    }
    frameLocator(selector) {
      return new FrameLocator(this, selector);
    }
    async $(selector) {
      const loc = this.locator(selector);
      const r = await loc._resolveAll();
      return r && r.handles.length ? new ElementHandle(r.frame, r.handles[0], loc._selector) : null;
    }
    async $$(selector) {
      const loc = this.locator(selector);
      const r = await loc._resolveAll();
      return r ? r.handles.map((h) => new ElementHandle(r.frame, h, loc._selector)) : [];
    }
    async $eval(selector, fn, arg) {
      const handle = await this.$(selector);
      if (!handle) throw new Error(`Error: failed to find element matching selector "${selector}"`);
      return handle.evaluate(fn, arg);
    }
    async $$eval(selector, fn, arg) {
      return this.locator(selector).evaluateAll(fn, arg);
    }
    async waitForSelector(selector, options = {}) {
      const loc = this.locator(selector);
      const state = options.state || "visible";
      await loc.waitFor({ ...options, state });
      if (state === "hidden" || state === "detached") return null;
      const r = await loc._resolveAll();
      return r && r.handles.length ? new ElementHandle(r.frame, r.handles[0], loc._selector) : null;
    }
    async waitForFunction(fn, arg, options = {}) {
      const timeout = options.timeout !== undefined ? options.timeout : this._session.defaultTimeout;
      const interval = typeof options.polling === "number" ? options.polling : 100;
      const source = functionSource(fn);
      const deadline = timeout ? this._session.now() + timeout : Infinity;
      for (;;) {
        try {
          const value = await this._call("page", source, [arg]);
          if (value) return value;
        } catch (e) {
          if (driverErrorCode(e) !== "stale") throw e;
        }
        if (this._session.now() >= deadline) throw new TimeoutError(`page.waitForFunction: Timeout ${timeout}ms exceeded.`);
        await this._session.sleep(interval);
      }
    }
    // Pointer-action entry points that take a selector, as on Playwright's Frame.
    click(selector, options) {
      return this.locator(selector).click(options);
    }
    dblclick(selector, options) {
      return this.locator(selector).dblclick(options);
    }
    fill(selector, value, options) {
      return this.locator(selector).fill(value, options);
    }
    type(selector, text, options) {
      return this.locator(selector).type(text, options);
    }
    press(selector, key, options) {
      return this.locator(selector).press(key, options);
    }
    hover(selector, options) {
      return this.locator(selector).hover(options);
    }
    focus(selector, options) {
      return this.locator(selector).focus(options);
    }
    check(selector, options) {
      return this.locator(selector).check(options);
    }
    uncheck(selector, options) {
      return this.locator(selector).uncheck(options);
    }
    selectOption(selector, values, options) {
      return this.locator(selector).selectOption(values, options);
    }
    setInputFiles(selector, files, options) {
      return this.locator(selector).setInputFiles(files, options);
    }
    dragAndDrop(source, target, options = {}) {
      return this.locator(source).dragTo(this.locator(target), options);
    }
    tap(selector, options) {
      return this.locator(selector).tap(options);
    }
    textContent(selector, options) {
      return this.locator(selector).textContent(options);
    }
    innerText(selector, options) {
      return this.locator(selector).innerText(options);
    }
    innerHTML(selector, options) {
      return this.locator(selector).innerHTML(options);
    }
    getAttribute(selector, name, options) {
      return this.locator(selector).getAttribute(name, options);
    }
    inputValue(selector, options) {
      return this.locator(selector).inputValue(options);
    }
    isVisible(selector, options) {
      return this.locator(selector).isVisible(options);
    }
    isHidden(selector, options) {
      return this.locator(selector).isHidden(options);
    }
    isEnabled(selector, options) {
      return this.locator(selector).isEnabled(options);
    }
    isDisabled(selector, options) {
      return this.locator(selector).isDisabled(options);
    }
    isChecked(selector, options) {
      return this.locator(selector).isChecked(options);
    }
    isEditable(selector, options) {
      return this.locator(selector).isEditable(options);
    }
    dispatchEvent(selector, type, init, options) {
      return this.locator(selector).dispatchEvent(type, init, options);
    }
    waitForLoadState(state, options) {
      return this._page.waitForLoadState(state, options);
    }
    waitForURL(url, options) {
      return this._page.waitForURL(url, options);
    }
    waitForTimeout(ms) {
      if (typeof ms !== "number" || !Number.isFinite(ms) || ms < 0) return Promise.reject(new Error(`waitForTimeout: timeout: expected a non-negative number, got ${JSON.stringify(ms)}`));
      return this._session.sleep(ms);
    }
  }

  // ---------------------------------------------------------------------------
  // Locator

  class Locator {
    constructor(frame, selector, options) {
      this._frame = frame;
      this._selector = selector;
      if (options && options.hasText !== undefined) this._selector += ` >> internal:has-text=${LU.escapeForTextSelector(options.hasText, false)}`;
      if (options && options.hasNotText !== undefined) this._selector += ` >> internal:has-not-text=${LU.escapeForTextSelector(options.hasNotText, false)}`;
      if (options && options.has) {
        if (options.has._frame !== frame) throw new Error('Inner "has" locator must belong to the same frame.');
        this._selector += " >> internal:has=" + JSON.stringify(options.has._selector);
      }
      if (options && options.hasNot) {
        if (options.hasNot._frame !== frame) throw new Error('Inner "hasNot" locator must belong to the same frame.');
        this._selector += " >> internal:has-not=" + JSON.stringify(options.hasNot._selector);
      }
      if (options && options.visible !== undefined) this._selector += ` >> visible=${options.visible ? "true" : "false"}`;
    }
    get _page() {
      return this._frame._page;
    }
    get _session() {
      return this._frame._session;
    }
    _timeout(options) {
      return options && options.timeout !== undefined ? options.timeout : this._session.defaultTimeout;
    }
    toString() {
      const ref = /^aria-ref=((f\d+)?e\d+)$/.exec(this._selector);
      return ref ? `ref('${ref[1]}')` : `locator('${this._selector}')`;
    }
    page() {
      return this._page;
    }

    // Resolves frame hops and returns every matching handle in the final
    // frame, or null when an intermediate frame is not there yet.
    async _resolveAll() {
      let frame = this._frame;
      let selector = this._selector;
      const ref = /^aria-ref=((f\d+)?e\d+)(?=$|\s)/.exec(selector);
      if (ref) {
        frame = await this._page._checkRef(ref[1]);
        selector = selector.replace(/^aria-ref=f\d+/, "aria-ref=");
      }
      const hops = await frame._agent("splitFrames", selector);
      for (let i = 0; i < hops.length - 1; i++) {
        const ids = await frame._agent("queryAll", hops[i]);
        if (!ids.length) return null;
        if (ids.length > 1) throw new Error(await frame._agent("strictError", hops[i], ids));
        const child = await frame._contentFrame(ids[0]);
        if (!child) return null;
        frame = child;
      }
      const handles = await frame._agent("queryAll", hops[hops.length - 1]);
      return { frame, handles, isRef: !!ref, ref: ref && ref[1] };
    }

    async _resolveOne(strict) {
      const r = await this._resolveAll();
      if (!r || !r.handles.length) return null;
      if (strict && r.handles.length > 1) throw new Error(await r.frame._agent("strictError", this._selector.split(" >> internal:control=enter-frame >> ").pop(), r.handles));
      return { frame: r.frame, handle: r.handles[0] };
    }

    async _waitForElement(options, title) {
      const timeout = this._timeout(options);
      return poll(this._session, timeout, title, async () => {
        const r = await this._resolveOne(true);
        return r ? { done: true, value: r } : { log: `waiting for ${this}` };
      });
    }

    async _scrollIntoView(frame, handle) {
      await frame._agent("scrollIntoViewIfNeeded", handle);
      // Bring each owner <iframe> into its parent's viewport too.
      for (let child = frame; child._parent; child = child._parent) {
        const parent = child._parent;
        const iframes = await parent._agent("iframeHandles");
        for (const h of iframes) {
          const f = await parent._contentFrame(h);
          if (f === child) {
            await parent._agent("scrollIntoViewIfNeeded", h);
            break;
          }
        }
      }
    }

    // Playwright's retrying pointer-action loop: wait for actionability,
    // scroll into view, find the click point, check the hit target.
    async _actionPoint(options, title, states) {
      const timeout = this._timeout(options);
      return poll(this._session, timeout, title, async () => {
        const r = await this._resolveOne(true);
        if (!r) return { log: `waiting for ${this}` };
        const { frame, handle } = r;
        if (!options.force) {
          const st = await frame._agent("checkStates", handle, states);
          if (st === "error:notconnected") return { log: "element is not attached to the DOM", now: true };
          if (st !== "done") return { log: `element is not ${st.missingState}` };
        }
        await this._scrollIntoView(frame, handle);
        let point;
        if (options.position) {
          const rect = await frame._agent("rect", handle);
          if (!rect) return { log: "element is not attached to the DOM" };
          point = { x: rect.x + options.position.x, y: rect.y + options.position.y };
        } else {
          point = await frame._agent("clickPoint", handle);
          if (point.error) return { log: point.error.replace("error:", "element is ") };
        }
        if (!options.force && !options.trial) {
          const hit = await frame._agent("hitTarget", handle, point, "button-link");
          if (hit !== "done") {
            // A target the page replaced meanwhile (a re-render) is looked up
            // again at once instead of after a back-off.
            if (!(await frame._agent("rect", handle).catch(() => null))) return { log: "element was detached from the DOM, retrying", now: true };
            return { log: `${hit} intercepts pointer events` };
          }
        }
        const offset = await frame._viewportOffset();
        return { done: true, value: { frame, handle, local: point, x: point.x + offset.x, y: point.y + offset.y } };
      });
    }

    // Moving the pointer can change layout (a :hover menu collapses), so the
    // hit target is checked again at the pointer's new position and the action
    // retried if something else is there now. Playwright gets the same effect
    // from its hit-target interceptor.
    async _pointer(options, title, states, perform) {
      options = options || {};
      const deadline = this._session.now() + this._timeout(options);
      let target;
      for (let attempt = 0; ; attempt++) {
        target = await this._actionPoint(options, title, states);
        if (options.trial) return;
        await this._page.mouse.move(target.x, target.y);
        if (options.force) break;
        const hit = await target.frame._agent("hitTarget", target.handle, target.local, "button-link").catch(() => "error:notconnected");
        if (hit === "done") break;
        // The page re-rendered the target since the check. When the locator
        // now matches the element under the pointer, that element is the
        // target: act on it at this point (as a person clicking there would).
        if (hit === "error:notconnected" || !(await target.frame._agent("rect", target.handle).catch(() => null))) {
          const again = await this._resolveOne(true).catch(() => null);
          if (again && again.frame === target.frame && (await again.frame._agent("hitTarget", again.handle, target.local, "button-link").catch(() => "")) === "done") {
            target = { ...target, handle: again.handle };
            break;
          }
          if (this._session.now() >= deadline) throw new TimeoutError(`${title}: Timeout ${this._timeout(options)}ms exceeded.\n  - element was detached from the DOM`);
          attempt--;
          continue;
        }
        if (this._session.now() >= deadline) throw new TimeoutError(`${title}: Timeout ${this._timeout(options)}ms exceeded.\n  - ${hit} intercepts pointer events`);
        await this._session.sleep([20, 50, 100, 100, 500][Math.min(attempt, 4)]);
      }
      await perform(target);
      await this._page._afterAction();
    }

    async click(options = {}) {
      return this._pointer(options, "locator.click", ["visible", "enabled", "stable"], (t) => this._page._clickAt(t, options));
    }
    async dblclick(options = {}) {
      return this._pointer(options, "locator.dblclick", ["visible", "enabled", "stable"], (t) =>
        this._page._clickAt(t, { ...options, clickCount: 2 }));
    }
    async tap(options = {}) {
      return this.click(options);
    }
    async hover(options = {}) {
      return this._pointer(options, "locator.hover", ["visible", "stable"], async (t) => {
        await this._page.mouse.move(t.x, t.y, { modifiers: options.modifiers });
      });
    }
    async dragTo(target, options = {}) {
      const from = await this._actionPoint({ ...options, position: options.sourcePosition }, "locator.dragTo", ["visible", "stable"]);
      const to = await target._actionPoint({ ...options, position: options.targetPosition, force: true }, "locator.dragTo", ["visible", "stable"]);
      const steps = options.steps || 1;
      const path = [{ x: from.x, y: from.y }];
      for (let i = 1; i <= steps; i++) path.push({ x: from.x + ((to.x - from.x) * i) / steps, y: from.y + ((to.y - from.y) * i) / steps });
      await this._page._input("input.drag", { targetId: this._page._targetId, path, button: "left", modifiers: normalizeModifiers(options.modifiers) });
      this._page.mouse._x = to.x;
      this._page.mouse._y = to.y;
      await this._page._afterAction();
    }
    async _withElement(options, title, states, fn) {
      const timeout = this._timeout(options);
      return poll(this._session, timeout, title, async () => {
        const r = await this._resolveOne(true);
        if (!r) return { log: `waiting for ${this}` };
        if (states && states.length && !(options && options.force)) {
          const st = await r.frame._agent("checkStates", r.handle, states);
          if (st === "error:notconnected") return { log: "element is not attached to the DOM" };
          if (st !== "done") return { log: `element is not ${st.missingState}` };
        }
        return { done: true, value: await fn(r.frame, r.handle) };
      });
    }
    async fill(value, options = {}) {
      const secret = this._page._isSecret(value) ? value : null;
      if (typeof value !== "string" && !secret) throw new Error(`locator.fill: value: expected string, got ${typeof value}`);
      await this._withElement(options, "locator.fill", ["visible", "enabled", "editable"], async (frame, handle) => {
        if (secret) {
          // Select the field's text with a stand-in value that passes the
          // field checks, then let the session type the secret over it.
          const r = await frame._agent("fill", handle, "0");
          if (r === "error:notconnected") throw Object.assign(new Error("Element is not attached to the DOM"), { code: "stale" });
          if (r !== "needsinput") throw new Error(`locator.fill: a secret can only be typed into a text field`);
          await this._page._insertSecret(secret, "locator.fill");
          return;
        }
        const r = await frame._agent("fill", handle, value);
        if (r === "error:notconnected") throw Object.assign(new Error("Element is not attached to the DOM"), { code: "stale" });
        if (r === "needsinput") {
          if (value) await this._page.keyboard.insertText(value);
          else await this._page.keyboard.press("Delete");
        }
      });
      await this._page._afterAction();
    }
    async clear(options = {}) {
      return this.fill("", options);
    }
    async _focusThen(options, title, fn) {
      let target = null;
      await this._withElement(options, title, [], async (frame, handle) => {
        await frame._agent("focus", handle, true);
        target = frame;
      });
      await fn(target);
      await this._page._afterAction();
    }
    // Text input that may be a secret(name) value, resolved for the frame
    // that receives it.
    async _typeInto(text, options, title) {
      if (typeof text !== "string" && !this._page._isSecret(text)) throw new Error(`${title}: text: expected string, got ${typeof text}`);
      if (this._page._isSecret(text)) return this._focusThen(options, title, () => this._page._insertSecret(text, title));
      return this._focusThen(options, title, () => this._page.keyboard.type(text, options));
    }
    async type(text, options = {}) {
      return this._typeInto(text, options, "locator.type");
    }
    async pressSequentially(text, options = {}) {
      return this._typeInto(text, options, "locator.pressSequentially");
    }
    async press(key, options = {}) {
      return this._focusThen(options, "locator.press", () => this._page.keyboard.press(key, options));
    }
    async _setChecked(checked, options, title) {
      const { frame, handle } = await this._waitForElement(options, title);
      const state = await frame._agent("elementState", handle, "checked");
      if (state.matches === checked) return;
      if (!checked && state.isRadio) throw new Error("Cannot uncheck radio button. Radio buttons can only be unchecked by selecting another radio button in the same group.");
      await this.click(options);
      if (options.trial) return;
      const after = await frame._agent("elementState", handle, "checked");
      if (after.matches !== checked) throw new Error("Clicking the checkbox did not change its state");
    }
    async check(options = {}) {
      return this._setChecked(true, options, "locator.check");
    }
    async uncheck(options = {}) {
      return this._setChecked(false, options, "locator.uncheck");
    }
    async setChecked(checked, options = {}) {
      return this._setChecked(!!checked, options, "locator.setChecked");
    }
    async selectOption(values, options = {}) {
      const list = values === null || values === undefined ? [] : Array.isArray(values) ? values : [values];
      const spec = list.map((v) => {
        if (typeof v === "string") return { valueOrLabel: v };
        if (v instanceof ElementHandle) return { handle: v._handle };
        return v;
      });
      const result = await this._withElement(options, "locator.selectOption", ["visible", "enabled"], (frame, handle) =>
        frame._agent("selectOptions", handle, spec));
      if (typeof result === "string" && result.startsWith("error:")) {
        if (result === "error:optionsnotfound") throw new Error("locator.selectOption: did not find some options");
        throw new Error(`locator.selectOption: ${result}`);
      }
      await this._page._afterAction();
      return result;
    }
    async setInputFiles(files, options = {}) {
      const payloads = await this._page._filePayloads(files);
      await this._withElement(options, "locator.setInputFiles", [], async (frame, handle) => {
        const target = await frame._agent("retarget", handle, "follow-label");
        if (!(await frame._agent("read", target, "isFileInput"))) throw new Error("Error: Node is not an HTMLInputElement");
        const multiple = await frame._agent("read", target, "multiple");
        if (payloads.length > 1 && !multiple) throw new Error("Error: Non-multiple file input can only accept single file");
        await this._session.call("input.setFiles", { targetId: this._page._targetId, frameId: frame._id || undefined, element: target, files: payloads });
      });
      await this._page._afterAction();
    }
    async focus(options = {}) {
      await this._withElement(options, "locator.focus", [], (frame, handle) => frame._agent("focus", handle, false));
    }
    async blur(options = {}) {
      await this._withElement(options, "locator.blur", [], (frame, handle) => frame._agent("blur", handle));
    }
    async dispatchEvent(type, eventInit, options = {}) {
      const dt = eventInit && eventInit.dataTransfer;
      if (dt && typeof dt === "object" && !Array.isArray(dt)) {
        // A drag event whose dataTransfer is described as { files, data }:
        // files as for setInputFiles (paths or { name, mimeType, buffer }),
        // data as { mimeType: string }. The page builds a real DataTransfer,
        // so a drop zone receives files the way a person's drop delivers them.
        const files = await this._page._filePayloads(dt.files);
        const data = dt.data || {};
        const init = { ...eventInit };
        delete init.dataTransfer;
        await this._withElement(options, "locator.dispatchEvent", [], (frame, handle) =>
          frame._call("page", `(el, type, init, files, data) => {
            const transfer = new DataTransfer();
            for (const f of files) {
              const bin = atob(f.base64);
              const bytes = new Uint8Array(bin.length);
              for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
              transfer.items.add(new File([bytes], f.name, { type: f.mimeType }));
            }
            for (const [mime, value] of Object.entries(data)) transfer.setData(mime, String(value));
            el.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, composed: true, ...init, dataTransfer: transfer }));
          }`, [type, init, files, data], [handle]));
        return;
      }
      await this._withElement(options, "locator.dispatchEvent", [], (frame, handle) => frame._agent("dispatchEvent", handle, type, eventInit || {}));
    }
    async selectText(options = {}) {
      await this._withElement(options, "locator.selectText", ["visible"], (frame, handle) => frame._agent("selectText", handle));
    }
    async scrollIntoViewIfNeeded(options = {}) {
      await this._withElement(options, "locator.scrollIntoViewIfNeeded", ["visible", "stable"], (frame, handle) => this._scrollIntoView(frame, handle));
    }
    async _box(frame, handle) {
      const rect = await frame._agent("rect", handle);
      if (!rect) return null;
      const offset = await frame._viewportOffset();
      return { x: rect.x + offset.x, y: rect.y + offset.y, width: rect.width, height: rect.height };
    }
    async boundingBox(options = {}) {
      return this._withElement(options, "locator.boundingBox", [], async (frame, handle) => {
        const visible = await frame._agent("elementState", handle, "visible");
        if (!visible.matches) return null;
        return this._box(frame, handle);
      });
    }
    async screenshot(options = {}) {
      const box = await this._withElement(options, "locator.screenshot", ["visible", "stable"], async (frame, handle) => {
        await this._scrollIntoView(frame, handle);
        return this._box(frame, handle);
      });
      return this._page.screenshot({ ...options, clip: box, fullPage: false });
    }
    async _read(what, arg, options, title) {
      return this._withElement(options || {}, title, [], (frame, handle) => frame._agent("read", handle, what, arg));
    }
    textContent(options) {
      return this._read("textContent", undefined, options, "locator.textContent");
    }
    innerText(options) {
      return this._read("innerText", undefined, options, "locator.innerText");
    }
    innerHTML(options) {
      return this._read("innerHTML", undefined, options, "locator.innerHTML");
    }
    getAttribute(name, options) {
      return this._read("getAttribute", name, options, "locator.getAttribute");
    }
    inputValue(options) {
      return this._read("inputValue", undefined, options, "locator.inputValue");
    }
    async _state(state, options, title) {
      return this._withElement(options || {}, title, [], async (frame, handle) => (await frame._agent("elementState", handle, state)).matches);
    }
    async isVisible() {
      const r = await this._resolveOne(true).catch((e) => {
        if (e instanceof StaleRefError || driverErrorCode(e) === "stale") return null;
        throw e;
      });
      if (!r) return false;
      return (await r.frame._agent("elementState", r.handle, "visible")).matches;
    }
    async isHidden() {
      return !(await this.isVisible());
    }
    isEnabled(options) {
      return this._state("enabled", options, "locator.isEnabled");
    }
    isDisabled(options) {
      return this._state("disabled", options, "locator.isDisabled");
    }
    isChecked(options) {
      return this._state("checked", options, "locator.isChecked");
    }
    isEditable(options) {
      return this._state("editable", options, "locator.isEditable");
    }
    async waitFor(options = {}) {
      const state = options.state || "visible";
      if (!["attached", "detached", "visible", "hidden"].includes(state)) {
        throw new Error(`locator.waitFor: state: expected one of (attached|detached|visible|hidden)`);
      }
      const timeout = this._timeout(options);
      await poll(this._session, timeout, "locator.waitFor", async () => {
        const r = await this._resolveAll().catch((e) => {
          if (driverErrorCode(e) === "stale") return null;
          throw e;
        });
        const handles = r ? r.handles : [];
        if (handles.length > 1 && state !== "detached" && state !== "hidden") {
          throw new Error(await r.frame._agent("strictError", this._selector, handles));
        }
        if (state === "attached") return { done: handles.length > 0 };
        if (state === "detached") return { done: handles.length === 0 };
        const visible = handles.length ? (await r.frame._agent("elementState", handles[0], "visible")).matches : false;
        // Say what the locator found, as Playwright's call log does.
        const found = !handles.length ? "" : visible ? "\n  - locator resolved to visible element" : "\n  - locator resolved to hidden element";
        return { done: state === "visible" ? visible : !visible, log: `waiting for ${this} to be ${state}${found}` };
      });
    }
    async evaluate(fn, arg, options) {
      return this._withElement(options || {}, "locator.evaluate", [], (frame, handle) =>
        frame._evalPage(`(el, arg) => (${functionSource(fn)})(el, arg)`, [arg], [handle]));
    }
    async evaluateHandle(fn, arg, options) {
      return this.evaluate(fn, arg, options);
    }
    async evaluateAll(fn, arg) {
      const r = await this._resolveAll();
      const frame = r ? r.frame : this._frame;
      const handles = r ? r.handles : [];
      return frame._evalPage(`(...xs) => (${functionSource(fn)})(xs.slice(0, ${handles.length}), xs[${handles.length}])`, [arg], handles);
    }
    async allTextContents() {
      return this.evaluateAll((els) => els.map((e) => e.textContent || ""));
    }
    async allInnerTexts() {
      return this.evaluateAll((els) => els.map((e) => e.innerText));
    }
    async count() {
      const r = await this._resolveAll();
      return r ? r.handles.length : 0;
    }
    async all() {
      const n = await this.count();
      return Array.from({ length: n }, (_, i) => this.nth(i));
    }
    async elementHandle(options) {
      const { frame, handle } = await this._waitForElement(options, "locator.elementHandle");
      return new ElementHandle(frame, handle, this._selector);
    }
    async elementHandles() {
      const r = await this._resolveAll();
      return r ? r.handles.map((h) => new ElementHandle(r.frame, h, this._selector)) : [];
    }
    async highlight() {}
    locator(selectorOrLocator, options) {
      if (typeof selectorOrLocator === "string") {
        return new Locator(this._frame, this._selector + " >> " + selectorOrLocator, options);
      }
      if (selectorOrLocator._frame !== this._frame) throw new Error("Locators must belong to the same frame.");
      return new Locator(this._frame, this._selector + " >> internal:chain=" + JSON.stringify(selectorOrLocator._selector), options);
    }
    getByRole(role, options) {
      return this.locator(LU.getByRoleSelector(role, options));
    }
    getByText(text, options) {
      return this.locator(LU.getByTextSelector(text, options));
    }
    getByLabel(text, options) {
      return this.locator(LU.getByLabelSelector(text, options));
    }
    getByPlaceholder(text, options) {
      return this.locator(LU.getByPlaceholderSelector(text, options));
    }
    getByAltText(text, options) {
      return this.locator(LU.getByAltTextSelector(text, options));
    }
    getByTitle(text, options) {
      return this.locator(LU.getByTitleSelector(text, options));
    }
    getByTestId(testId) {
      return this.locator(LU.getByTestIdSelector(this._page._testIdAttribute, testId));
    }
    frameLocator(selector) {
      return new FrameLocator(this._frame, this._selector + " >> " + selector);
    }
    contentFrame() {
      return new FrameLocator(this._frame, this._selector);
    }
    filter(options) {
      return new Locator(this._frame, this._selector, options);
    }
    first() {
      return new Locator(this._frame, this._selector + " >> nth=0");
    }
    last() {
      return new Locator(this._frame, this._selector + " >> nth=-1");
    }
    nth(index) {
      if (!Number.isInteger(index)) throw new Error(`locator.nth: index: expected an integer, got ${JSON.stringify(index)}`);
      return new Locator(this._frame, this._selector + ` >> nth=${index}`);
    }
    and(locator) {
      if (locator._frame !== this._frame) throw new Error("Locators must belong to the same frame.");
      return new Locator(this._frame, this._selector + " >> internal:and=" + JSON.stringify(locator._selector));
    }
    or(locator) {
      if (locator._frame !== this._frame) throw new Error("Locators must belong to the same frame.");
      return new Locator(this._frame, this._selector + " >> internal:or=" + JSON.stringify(locator._selector));
    }
  }

  // A locator pinned to one element, returned by page.$() and friends.
  class ElementHandle extends Locator {
    constructor(frame, handle, selector) {
      super(frame, selector || "");
      this._pinnedFrame = frame;
      this._handle = handle;
    }
    async _resolveAll() {
      return { frame: this._pinnedFrame, handles: [this._handle] };
    }
    async _resolveOne() {
      return { frame: this._pinnedFrame, handle: this._handle };
    }
    asElement() {
      return this;
    }
    async ownerFrame() {
      return this._pinnedFrame;
    }
    async contentFrame() {
      return this._pinnedFrame._contentFrame(this._handle);
    }
    async dispose() {}
    async $(selector) {
      const ids = await this._pinnedFrame._agent("queryAll", selector, this._handle);
      return ids.length ? new ElementHandle(this._pinnedFrame, ids[0], selector) : null;
    }
    async $$(selector) {
      const ids = await this._pinnedFrame._agent("queryAll", selector, this._handle);
      return ids.map((h) => new ElementHandle(this._pinnedFrame, h, selector));
    }
    async $eval(selector, fn, arg) {
      const h = await this.$(selector);
      if (!h) throw new Error(`Error: failed to find element matching selector "${selector}"`);
      return h.evaluate(fn, arg);
    }
    async $$eval(selector, fn, arg) {
      const ids = await this._pinnedFrame._agent("queryAll", selector, this._handle);
      return this._pinnedFrame._evalPage(`(...xs) => (${functionSource(fn)})(xs.slice(0, ${ids.length}), xs[${ids.length}])`, [arg], ids);
    }
    toString() {
      return "JSHandle@node";
    }
  }

  class FrameLocator {
    constructor(frame, selector) {
      this._frame = frame;
      this._frameSelector = selector;
    }
    locator(selectorOrLocator, options) {
      const inner = typeof selectorOrLocator === "string" ? selectorOrLocator : selectorOrLocator._selector;
      return new Locator(this._frame, this._frameSelector + " >> internal:control=enter-frame >> " + inner, options);
    }
    getByRole(role, options) {
      return this.locator(LU.getByRoleSelector(role, options));
    }
    getByText(text, options) {
      return this.locator(LU.getByTextSelector(text, options));
    }
    getByLabel(text, options) {
      return this.locator(LU.getByLabelSelector(text, options));
    }
    getByPlaceholder(text, options) {
      return this.locator(LU.getByPlaceholderSelector(text, options));
    }
    getByAltText(text, options) {
      return this.locator(LU.getByAltTextSelector(text, options));
    }
    getByTitle(text, options) {
      return this.locator(LU.getByTitleSelector(text, options));
    }
    getByTestId(testId) {
      return this.locator(LU.getByTestIdSelector(this._frame._page._testIdAttribute, testId));
    }
    frameLocator(selector) {
      return new FrameLocator(this._frame, this._frameSelector + " >> internal:control=enter-frame >> " + selector);
    }
    first() {
      return new FrameLocator(this._frame, this._frameSelector + " >> nth=0");
    }
    last() {
      return new FrameLocator(this._frame, this._frameSelector + " >> nth=-1");
    }
    nth(index) {
      return new FrameLocator(this._frame, this._frameSelector + ` >> nth=${index}`);
    }
    owner() {
      return new Locator(this._frame, this._frameSelector);
    }
  }

  // ---------------------------------------------------------------------------
  // Keyboard and mouse

  class Keyboard {
    constructor(page) {
      this._page = page;
      this._modifiers = new Set();
    }
    async _send(type, desc, detached) {
      await this._page._input("input.key", {
        targetId: this._page._targetId,
        type,
        key: desc.key,
        code: desc.code,
        text: type === "down" ? desc.text || undefined : undefined,
        location: desc.location,
        modifiers: [...this._modifiers],
      }, detached);
    }
    async down(key) {
      const desc = describeKey(key, this._modifiers);
      if (MODIFIERS.includes(desc.key)) this._modifiers.add(desc.key);
      await this._send("down", desc);
    }
    async up(key) {
      const desc = describeKey(key, this._modifiers);
      if (MODIFIERS.includes(desc.key)) this._modifiers.delete(desc.key);
      await this._send("up", desc);
    }
    async insertText(text) {
      if (this._page._isSecret(text)) throw new Error("keyboard.insertText: a secret is typed into an element, so its domain can be checked: use locator.fill(secret(name)) or locator.type(secret(name))");
      if (typeof text !== "string") throw new Error(`keyboard.insertText: text: expected string, got ${typeof text}`);
      await this._page._input("input.insertText", { targetId: this._page._targetId, text });
    }
    async press(combo, options = {}) {
      const tokens = splitKeyCombo(combo);
      const key = tokens.pop();
      for (const t of tokens) await this.down(t);
      await this.down(key);
      // A key that opened a dialog is released once the dialog is answered.
      const detached = !!this._page._heldDialog;
      if (options.delay && !detached) await this._page._session.sleep(options.delay);
      await this._release(key, detached);
      for (const t of tokens.reverse()) await this._release(t, detached);
    }
    async _release(key, detached) {
      const desc = describeKey(key, this._modifiers);
      if (MODIFIERS.includes(desc.key)) this._modifiers.delete(desc.key);
      await this._send("up", desc, detached);
    }
    async type(text, options = {}) {
      if (this._page._isSecret(text)) throw new Error("keyboard.type: a secret is typed into an element, so its domain can be checked: use locator.fill(secret(name)) or locator.type(secret(name))");
      if (typeof text !== "string") throw new Error(`keyboard.type: text: expected string, got ${typeof text}`);
      for (const ch of text) {
        if (KEYS[ch]) await this.press(ch, options);
        else await this.insertText(ch);
        if (options.delay) await this._page._session.sleep(options.delay);
      }
    }
  }

  // Like Playwright's goto: an absolute URL with a scheme, or a bare host
  // that the driver completes; words with spaces are not a URL.
  function checkNavigableURL(title, url) {
    if (typeof url !== "string" || !url.trim()) throw new Error(`${title}: url: expected a non-empty string, got ${JSON.stringify(url)}`);
    if (/\s/.test(url.trim()) || !/^[a-z][a-z0-9+.-]*:|^[\w.-]+(:\d+)?(\/|$)/i.test(url.trim())) {
      throw new Error(`${title}: Cannot navigate to invalid URL: expected an absolute URL, got ${JSON.stringify(url)}`);
    }
  }
  ns.checkNavigableURL = checkNavigableURL;

  function checkPoint(title, x, y) {
    if (typeof x !== "number" || typeof y !== "number" || !Number.isFinite(x) || !Number.isFinite(y)) throw new Error(`${title}: x and y: expected numbers, got ${JSON.stringify(x)}, ${JSON.stringify(y)}`);
  }

  class Mouse {
    constructor(page) {
      this._page = page;
      this._x = 0;
      this._y = 0;
      this._buttons = new Set();
    }
    _event(type, extra, detached) {
      return this._page._input("input.mouse", {
        targetId: this._page._targetId,
        type,
        x: this._x,
        y: this._y,
        button: "left",
        clickCount: 0,
        modifiers: [...this._page.keyboard._modifiers],
        ...extra,
      }, detached);
    }
    async move(x, y, options = {}) {
      checkPoint("mouse.move", x, y);
      const steps = options.steps || 1;
      const fromX = this._x;
      const fromY = this._y;
      for (let i = 1; i <= steps; i++) {
        this._x = fromX + ((x - fromX) * i) / steps;
        this._y = fromY + ((y - fromY) * i) / steps;
        await this._event("move", options.modifiers ? { modifiers: normalizeModifiers(options.modifiers) } : {});
      }
    }
    async down(options = {}) {
      const button = options.button || "left";
      this._buttons.add(button);
      await this._event("down", { button, clickCount: options.clickCount || 1 });
    }
    async up(options = {}) {
      const button = options.button || "left";
      this._buttons.delete(button);
      await this._event("up", { button, clickCount: options.clickCount || 1 }, !!this._page._heldDialog);
    }
    async click(x, y, options = {}) {
      checkPoint("mouse.click", x, y);
      await this.move(x, y);
      const count = options.clickCount || 1;
      for (let i = 1; i <= count; i++) {
        await this.down({ button: options.button, clickCount: i });
        if (options.delay && !this._page._heldDialog) await this._page._session.sleep(options.delay);
        await this.up({ button: options.button, clickCount: i });
        if (this._page._heldDialog) break;
      }
      await this._page._afterAction();
    }
    async dblclick(x, y, options = {}) {
      return this.click(x, y, { ...options, clickCount: 2 });
    }
    async wheel(deltaX, deltaY) {
      if (typeof deltaX !== "number" || typeof deltaY !== "number" || !Number.isFinite(deltaX) || !Number.isFinite(deltaY)) throw new Error(`mouse.wheel: deltaX and deltaY: expected numbers, got ${JSON.stringify(deltaX)}, ${JSON.stringify(deltaY)}`);
      await this._event("wheel", { deltaX, deltaY });
    }
  }

  // ---------------------------------------------------------------------------
  // Event payload objects

  class Dialog {
    constructor(page, payload) {
      this._page = page;
      this._p = payload;
      // A dialog that opened during Copy, Cut or Paste arrives answered.
      this._handled = !!payload.dismissedDuring;
    }
    type() {
      return this._p.type;
    }
    message() {
      return this._p.message;
    }
    defaultValue() {
      return this._p.defaultValue || "";
    }
    page() {
      return this._page;
    }
    async _respond(accept, promptText) {
      // cmux already answered it; a listener's answer has nothing to do.
      if (this._p.dismissedDuring) return;
      if (this._handled) throw new Error("Cannot accept dialog which is already handled!");
      // Validate before answering: a rejected answer must leave the dialog
      // open and known, or the page stays blocked with no dialog to answer.
      if (promptText !== undefined && typeof promptText !== "string") throw new Error(`dialog.accept: promptText: expected string, got ${typeof promptText}`);
      this._handled = true;
      if (this._page._heldDialog === this) this._page._heldDialog = null;
      if (this._page._listenedDialog === this) this._page._listenedDialog = null;
      await this._page._session.call("dialog.respond", { targetId: this._page._targetId, dialogId: this._p.dialogId, accept, promptText });
    }
    accept(promptText) {
      return this._respond(true, promptText);
    }
    dismiss() {
      return this._respond(false);
    }
  }

  class FileChooser {
    constructor(page, payload) {
      this._page = page;
      this._p = payload;
    }
    page() {
      return this._page;
    }
    element() {
      return new ElementHandle(this._page._frameFor(this._p.frameId), this._p.element);
    }
    isMultiple() {
      return !!this._p.multiple;
    }
    _settle() {
      if (this._handled) throw new Error("File chooser was already answered");
      this._handled = true;
      if (this._page._heldChooser === this) this._page._heldChooser = null;
    }
    async setFiles(files) {
      const payloads = await this._page._filePayloads(files);
      if (payloads.length > 1 && !this.isMultiple()) throw new Error("Error: Non-multiple file input can only accept single file");
      this._settle();
      await this._page._session.call("filechooser.respond", { targetId: this._page._targetId, chooserId: this._p.chooserId, files: payloads });
    }
    async cancel() {
      this._settle();
      await this._page._session.call("filechooser.respond", { targetId: this._page._targetId, chooserId: this._p.chooserId, cancel: true });
    }
  }

  class Download {
    constructor(page, payload) {
      this._page = page;
      this._p = payload;
      this._finished = new Promise((resolve) => (this._resolveFinished = resolve));
    }
    page() {
      return this._page;
    }
    url() {
      return this._p.url;
    }
    suggestedFilename() {
      return this._p.suggestedFilename;
    }
    async path() {
      // A finished download's path is state: use it when the event came.
      const done = this._outcome;
      const { path } = done && done.path ? done : await this._page._session.call("download.path", { downloadId: this._p.downloadId });
      if (this._page._session.onDownloadPath) this._page._session.onDownloadPath(path);
      return path;
    }
    async failure() {
      const r = await this._finished;
      return r.error || null;
    }
    async saveAs(target) {
      const files = this._page._session.files;
      if (!files) throw new Error("download.saveAs is not available in this session");
      const bytes = await files.readAbsolute(await this.path());
      await files.write(target, bytes);
    }
    async cancel() {}
    async delete() {}
  }

  class ConsoleMessage {
    constructor(page, p) {
      this._page = page;
      this._p = p;
    }
    type() {
      return this._p.type;
    }
    text() {
      return this._p.text;
    }
    args() {
      return this._p.args || [];
    }
    location() {
      return this._p.location || { url: "", lineNumber: 0, columnNumber: 0 };
    }
    page() {
      return this._page;
    }
    toString() {
      return this._p.text;
    }
    toJSON() {
      return { type: this._p.type, text: this._p.text };
    }
  }

  // Per-tab virtual clipboard. Meta+C, Meta+X and Meta+V in the tab use it;
  // the system clipboard is never read or written.
  class TabClipboard {
    constructor(page) {
      this._page = page;
    }
    _call(method, params) {
      return this._page._session.call(method, Object.assign({ targetId: this._page._targetId }, params));
    }
    async read() {
      const { items } = await this._call("clipboard.read", {});
      return (items || []).map((i) => ({ type: i.type, data: Buffer.from(i.base64, "base64") }));
    }
    async readText() {
      const { items } = await this._call("clipboard.read", {});
      const text = (items || []).find((i) => i.type === "text/plain");
      return text ? Buffer.from(text.base64, "base64").toString("utf8") : "";
    }
    // Items are { type, data } (data a string or bytes), or
    // { entries: [{ mimeType, text | data }] } as reference B writes
    // them; every entry of every item lands on the clipboard.
    async write(items) {
      const list = [].concat(items === undefined ? [] : items);
      const flat = [];
      for (const i of list) {
        if (!i || typeof i !== "object") throw new Error(`clipboard.write: items: expected objects, got ${JSON.stringify(i)}`);
        for (const e of Array.isArray(i.entries) ? i.entries : [i]) {
          const type = e.type || e.mimeType || "text/plain";
          const value = e.data !== undefined ? e.data : e.text;
          if (value === undefined || value === null) throw new Error(`clipboard.write: item ${JSON.stringify(type)} has no data or text`);
          flat.push({ type, base64: Buffer.from(typeof value === "string" ? value : value).toString("base64") });
        }
      }
      if (!flat.length) throw new Error("clipboard.write: expected at least one clipboard item, got none");
      await this._call("clipboard.write", { items: flat });
    }
    async writeText(text) {
      if (typeof text !== "string") throw new Error(`clipboard.writeText: text: expected string, got ${typeof text}`);
      await this.write([{ type: "text/plain", data: text }]);
    }
  }

  class Request {
    constructor(page, p) {
      this._page = page;
      this._p = p;
    }
    url() {
      return this._p.url;
    }
    method() {
      return this._p.method;
    }
    resourceType() {
      return this._p.resourceType;
    }
    headers() {
      return this._p.headers || {};
    }
    frame() {
      return this._page.mainFrame();
    }
    isNavigationRequest() {
      return this._p.resourceType === "document";
    }
  }

  class Response {
    constructor(page, p, request) {
      this._page = page;
      this._p = p;
      this._request = request;
    }
    url() {
      return this._p.url;
    }
    status() {
      return this._p.status;
    }
    ok() {
      return this._p.status === 0 || (this._p.status >= 200 && this._p.status <= 299);
    }
    headers() {
      return this._p.headers || {};
    }
    request() {
      return this._request;
    }
    frame() {
      return this._page.mainFrame();
    }
  }

  // ---------------------------------------------------------------------------
  // Page

  // Unfinished requests a page keeps to pair with their later events.
  const MAX_OPEN_REQUESTS = 1000;

  class Page extends EventEmitter {
    constructor(session, targetId) {
      super();
      this._session = session;
      this._targetId = targetId;
      this._url = "";
      this._closed = false;
      this._opener = null;
      this._mainFrame = new Frame(this, null, null);
      this._frames = new Map();
      this._requests = new Map();
      this._testIdAttribute = "data-testid";
      // Frame prefixes are assigned once per frame, in DOM order of first
      // sight, so a frame's refs keep their prefix.
      this._framePrefixes = new Map();
      this._prefixFrames = new Map([["", this._mainFrame]]);
      this._prefixCounter = 0;
      this._refMax = new Map();
      this._heldDialog = null;
      this._listenedDialog = null;
      this._dismissedDialogs = [];
      this._heldChooser = null;
      this._dialogWatchers = new Set();
      this._consoleHistory = [];
      this._pageErrors = [];
      this._kept = false;
      this.keyboard = new Keyboard(this);
      this.mouse = new Mouse(this);
      this.touchscreen = { tap: (x, y) => this.mouse.click(x, y) };
    }
    get targetId() {
      return this._targetId;
    }
    get id() {
      return this._targetId;
    }
    // Listeners for the events a session can take over from the user's UI
    // are reported to the driver (`tab.handleEvents`): in a user's tab the
    // session only drives, an event reaches the session only while it has
    // a listener here (docs/browser-repl/README.md, Sessions and tabs).
    on(event, handler) {
      super.on(event, handler);
      this._syncHandledEvents(event);
      return this;
    }
    once(event, handler) {
      super.once(event, handler);
      this._syncHandledEvents(event);
      return this;
    }
    off(event, handler) {
      super.off(event, handler);
      this._syncHandledEvents(event);
      return this;
    }
    removeAllListeners(event) {
      super.removeAllListeners(event);
      this._syncHandledEvents(event);
      return this;
    }
    emit(event, ...args) {
      const r = super.emit(event, ...args);
      // A `once` listener is gone after it ran.
      this._syncHandledEvents(event);
      return r;
    }
    _syncHandledEvents(event) {
      if (event !== undefined && !HANDLED_EVENTS.includes(event)) return;
      // A tab not opened yet will be one this session opened; those route
      // every event to the session anyway.
      if (this._closed || this._targetId.startsWith("lazy:")) return;
      const events = HANDLED_EVENTS.filter((e) => this.listenerCount(e) > 0);
      const key = events.join(",");
      if (key === (this._handledKey === undefined || this._handledKey === null ? "" : this._handledKey)) return;
      this._handledKey = key;
      // Updates go out in order, and the session's next call on this tab
      // waits for them (Session.call), so a listener added right before an
      // action is in place when the action's event fires.
      const targetId = this._targetId;
      const driver = this._session.driver;
      const p = (this._handledSync || Promise.resolve())
        .then(() => driver.call("tab.handleEvents", { targetId, events }))
        .catch(() => {})
        .finally(() => {
          if (this._handledSync === p) this._handledSync = null;
        });
      this._handledSync = p;
    }
    _normalizeSelector(selector) {
      if (typeof selector === "string" && REF_PATTERN.test(selector.trim())) return `aria-ref=${selector.trim()}`;
      return selector;
    }
    _frameFor(frameId, parent) {
      if (!frameId || frameId === this._mainFrame._id) return this._mainFrame;
      let frame = this._frames.get(frameId);
      if (!frame) {
        frame = new Frame(this, frameId, parent || this._mainFrame);
        this._frames.set(frameId, frame);
      } else if (parent && frame._parent !== parent) {
        frame._parent = parent;
      }
      return frame;
    }
    async _refreshFrames() {
      const list = await this._session.call("frames.list", { targetId: this._targetId });
      const alive = new Set();
      for (const f of list) {
        if (!f.parentFrameId) {
          this._mainFrame._id = f.frameId;
          this._mainFrame._url = f.url;
          // An event may have named the main frame before its id was known.
          this._frames.delete(f.frameId);
          alive.add(this._mainFrame);
          continue;
        }
        const frame = this._frameFor(f.frameId, this._frameFor(f.parentFrameId));
        frame._url = f.url;
        frame._name = f.name || "";
        frame._crossOrigin = !!f.crossOrigin;
        alive.add(frame);
      }
      for (const [id, frame] of this._frames) {
        if (!alive.has(frame)) {
          frame._detached = true;
          this._frames.delete(id);
        }
      }
      return list;
    }
    _prefixFor(frame) {
      if (frame === this._mainFrame) return "";
      let prefix = this._framePrefixes.get(frame);
      if (!prefix) {
        prefix = `f${++this._prefixCounter}`;
        this._framePrefixes.set(frame, prefix);
        this._prefixFrames.set(prefix, frame);
      }
      return prefix;
    }
    _frameForPrefix(prefix) {
      const frame = this._prefixFrames.get(prefix || "");
      return frame && !frame._detached ? frame : null;
    }
    _refMaxFor(frame) {
      return this._refMax.get(frame) || 0;
    }
    _noteRefMax(frame, max) {
      if (typeof max === "number" && max > this._refMaxFor(frame)) this._refMax.set(frame, max);
    }
    // Returns the frame that owns a live ref, or throws: a ref whose element
    // is gone never rebinds to another element.
    async _checkRef(ref) {
      const [, prefix = "", local] = REF_PATTERN.exec(ref);
      const stale = () => new StaleRefError(`ref ${ref} is stale: the element was removed; take a new snapshot`);
      let frame = this._frameForPrefix(prefix);
      if (!frame) {
        if (this._prefixFrames.has(prefix)) throw stale();
        throw new StaleRefError(`ref ${ref} does not exist; take a new snapshot`);
      }
      let state;
      try {
        state = await frame._agent("refState", local, this._refMaxFor(frame));
      } catch (e) {
        if (driverErrorCode(e) === "stale" || driverErrorCode(e) === "not_found") {
          await this._refreshFrames().catch(() => {});
          if (frame._detached) throw stale();
        }
        throw e;
      }
      if (state.live) return frame;
      if (Number(local.slice(1)) <= Math.max(state.max, this._refMaxFor(frame))) throw stale();
      throw new StaleRefError(`ref ${ref} does not exist; take a new snapshot`);
    }
    async _refForHandle(frame, handle) {
      const r = await frame._agent("refForHandle", handle, this._refMaxFor(frame));
      this._noteRefMax(frame, r.max);
      return this._prefixFor(frame) + r.ref;
    }
    _pendingDialog() {
      const d = this._heldDialog || this._listenedDialog;
      return d && !d._handled ? d : null;
    }
    _pendingChooser() {
      const c = this._heldChooser;
      return c && !c._handled ? c : null;
    }
    _blockedError() {
      const d = this._heldDialog;
      if (!d || d._handled) return null;
      return new Error(`page is blocked by a JavaScript ${d.type()} dialog ${JSON.stringify(d.message())}; answer it with page.dialog().accept() or page.dialog().dismiss()`);
    }
    // Settles when `promise` does, or when a dialog nobody listens for opens:
    // input then counts as delivered, an evaluation fails with the way out.
    _raceDialog(promise, isEvaluation) {
      return new Promise((resolve, reject) => {
        let settled = false;
        const watcher = () => {
          if (settled) return;
          settled = true;
          this._dialogWatchers.delete(watcher);
          promise.catch(() => {});
          if (isEvaluation) reject(this._blockedError());
          else resolve(undefined);
        };
        this._dialogWatchers.add(watcher);
        promise.then(
          (v) => {
            if (settled) return;
            settled = true;
            this._dialogWatchers.delete(watcher);
            resolve(v);
          },
          (e) => {
            if (settled) return;
            settled = true;
            this._dialogWatchers.delete(watcher);
            reject(e);
          },
        );
      });
    }
    // Native input. `detached` sends without waiting, for the release of a
    // key or button whose press opened a dialog.
    _input(method, params, detached) {
      if (detached) {
        this._session.call(method, params).catch(() => {});
        return Promise.resolve();
      }
      const blocked = this._blockedError();
      if (blocked) return Promise.reject(blocked);
      return this._raceDialog(this._session.call(method, params), false);
    }
    async _afterAction() {
      await this._syncInfo().catch(() => {});
      if (!this._heldDialog) await this._refreshFrames().catch(() => {});
      if (this._session.agentTools) await this._session.agentTools.afterAction(this);
    }
    _isSecret(value) {
      return !!(this._session.agentTools && this._session.agentTools.isSecret(value));
    }
    // Types a secret(name) into the focused element. The value never
    // enters this context: the native session substitutes it and the
    // driver types it only when the focused frame's own origin matches the
    // secret's domains, checked again on every call (so on every retry).
    async _insertSecret(secret, title) {
      try {
        await this._input("input.insertText", { targetId: this._targetId, secret: secret.name });
      } catch (e) {
        if (e && /^secret /.test(e.message || "")) throw new Error(`${title}: ${e.message}`);
        throw e;
      }
    }
    async _syncInfo() {
      if (this._closed) throw new Error("Target page, context or browser has been closed");
      const info = await this._session.call("tab.info", { targetId: this._targetId });
      this._url = info.url;
      this._title = info.title;
      this._viewport = info.viewport;
      return info;
    }
    async _clickAt(target, options) {
      const button = options.button || "left";
      const count = options.clickCount || 1;
      const modifiers = normalizeModifiers(options.modifiers);
      const call = (type, extra, detached) => this._input("input.mouse", {
        targetId: this._targetId, type, x: target.x, y: target.y, button, clickCount: 0, modifiers, ...extra,
      }, detached);
      await call("move");
      this.mouse._x = target.x;
      this.mouse._y = target.y;
      const activeBefore = await target.frame._agent("activeHandle").catch(() => undefined);
      for (let i = 1; i <= count; i++) {
        await call("down", { clickCount: i });
        const opened = !!this._heldDialog;
        if (i === 1 && !opened) await target.frame._agent("emulateClickFocus", target.handle, activeBefore).catch(() => {});
        if (options.delay && !opened) await this._session.sleep(options.delay);
        await call("up", { clickCount: i }, opened);
        if (this._heldDialog) break;
      }
    }
    async _filePayloads(files) {
      const list = files === undefined || files === null ? [] : Array.isArray(files) ? files : [files];
      const out = [];
      for (const f of list) {
        if (typeof f === "string") {
          const fsApi = this._session.files;
          if (!fsApi) throw new Error("File uploads are not available in this session");
          const bytes = await fsApi.read(f);
          const name = f.split("/").pop();
          out.push({ name, mimeType: mimeTypeFor(name), base64: base64Encode(bytes) });
        } else {
          const bytes = typeof f.buffer === "string" ? Buffer.from(f.buffer) : f.buffer;
          out.push({ name: f.name, mimeType: f.mimeType || mimeTypeFor(f.name), base64: base64Encode(bytes) });
        }
      }
      return out;
    }

    // Driver events
    // The web content process died. Like Playwright's page 'crash': calls
    // fail until the page navigates or reloads, which starts a new process.
    _onCrashed() {
      this._crashed = true;
      // The next web process has new frame ids; address the main frame by
      // default until frames are read again.
      this._mainFrame._id = null;
      for (const [, frame] of this._frames) frame._detached = true;
      this._frames.clear();
      this.emit("crash", this);
    }
    _onClosed() {
      if (this._closed) return;
      this._closed = true;
      this._session.pages.delete(this._targetId);
      this._session.closedTargets.add(this._targetId);
      this.emit("close", this);
    }
    _onNavigated(p) {
      const frame = this._frameFor(p.frameId);
      if (frame === this._mainFrame) {
        this._mainFrame._id = this._mainFrame._id || p.frameId;
        this._url = p.url;
      } else frame._url = p.url;
      this.emit("framenavigated", frame);
    }
    _onLoadState(p) {
      if (p.state === "load" || p.state === "domcontentloaded") this.emit(p.state, this);
    }
    // With a "dialog" listener the listener answers, as in Playwright.
    // Without one the dialog stays open, shows in the snapshot and is answered
    // through page.dialog(); nothing is dismissed silently. A dialog that
    // opened during Copy, Cut or Paste was already dismissed so it could not
    // hold the command: listeners still get it, and the next snapshot
    // reports it once.
    _onDialog(p) {
      const dialog = new Dialog(this, p);
      if (p.dismissedDuring) {
        this._dismissedDialogs.push(dialog);
        if (this._dismissedDialogs.length > 20) this._dismissedDialogs.shift();
        this.emit("dialog", dialog);
        return;
      }
      if (this.listenerCount("dialog")) {
        this._listenedDialog = dialog;
        this.emit("dialog", dialog);
        return;
      }
      this._heldDialog = dialog;
      for (const watcher of [...this._dialogWatchers]) watcher(dialog);
    }
    _onFileChooser(p) {
      const chooser = new FileChooser(this, p);
      if (this.listenerCount("filechooser")) {
        this.emit("filechooser", chooser);
        return;
      }
      this._heldChooser = chooser;
    }
    _onDownload(p) {
      const download = new Download(this, p);
      (this._downloads || (this._downloads = new Map())).set(p.downloadId, download);
      this.emit("download", download);
    }
    _onDownloadFinished(p) {
      const d = this._downloads && this._downloads.get(p.downloadId);
      if (d) {
        d._outcome = p;
        d._resolveFinished(p);
      }
    }
    _onConsole(p) {
      const message = new ConsoleMessage(this, p.type === "warn" ? Object.assign({}, p, { type: "warning" }) : p);
      this._consoleHistory.push(message);
      if (this._consoleHistory.length > 1000) this._consoleHistory.shift();
      this.emit("console", message);
    }
    _onPageError(p) {
      const e = new Error(p.message);
      e.stack = p.stack || e.stack;
      this._pageErrors.push(e);
      if (this._pageErrors.length > 200) this._pageErrors.shift();
      this.emit("pageerror", e);
    }
    _onNetwork(p, event) {
      if (event === "request") {
        const req = new Request(this, p);
        this._requests.set(p.requestId, req);
        // Requests that never finish (streams, long polls, a page that
        // opens them without end) keep only the newest; a later event for
        // an evicted one builds its Request from the event.
        if (this._requests.size > MAX_OPEN_REQUESTS) this._requests.delete(this._requests.keys().next().value);
        this.emit("request", req);
        return;
      }
      const req = this._requests.get(p.requestId) || new Request(this, p);
      if (event === "response") this.emit("response", new Response(this, p, req));
      else {
        this._requests.delete(p.requestId);
        this.emit(event, req);
      }
    }

    // Public API: cmux additions (docs/browser-repl/README.md, Page additions)
    ref(ref) {
      if (typeof ref !== "string" || !REF_PATTERN.test(ref.trim())) {
        throw new Error(`page.ref: expected a snapshot ref such as "e5" or "f1e2", got ${JSON.stringify(ref)}`);
      }
      return this.locator(ref.trim());
    }
    dialog() {
      const d = this._pendingDialog();
      if (!d) return null;
      return {
        type: d.type(),
        message: d.message(),
        defaultValue: d.defaultValue(),
        accept: (text) => d.accept(text),
        dismiss: () => d.dismiss(),
      };
    }
    fileChooser() {
      const c = this._pendingChooser();
      if (!c) return null;
      return { multiple: c.isMultiple(), setFiles: (files) => c.setFiles(files), cancel: () => c.cancel() };
    }
    async consoleMessages(options = {}) {
      const LEVELS = ["log", "debug", "info", "error", "warning", "dir", "dirxml", "table", "trace", "clear", "startGroup", "startGroupCollapsed", "endGroup", "assert", "profile", "profileEnd", "count", "timeEnd"];
      if (options.limit !== undefined && (!Number.isInteger(options.limit) || options.limit < 1)) throw new Error(`page.consoleMessages: limit must be a positive integer, got ${JSON.stringify(options.limit)}`);
      if (options.filter !== undefined && typeof options.filter !== "string" && !isRegExp(options.filter)) throw new Error("page.consoleMessages: filter must be a string or a RegExp");
      for (const l of options.level === undefined ? [] : [].concat(options.level)) {
        if (!LEVELS.includes(l === "warn" ? "warning" : l)) throw new Error(`page.consoleMessages: invalid level ${JSON.stringify(l)}; expected one of log, debug, info, warning, error`);
      }
      let list = this._consoleHistory.slice();
      if (options.level) {
        const levels = [].concat(options.level).map((l) => (l === "warn" ? "warning" : l));
        list = list.filter((m) => levels.includes(m.type()));
      }
      if (options.filter !== undefined) {
        const f = options.filter;
        list = list.filter((m) => (isRegExp(f) ? f.test(m.text()) : m.text().includes(String(f))));
      }
      if (options.limit) list = list.slice(-options.limit);
      return list;
    }
    async errors() {
      return this._pageErrors.slice();
    }
    async pageErrors() {
      return this.errors();
    }
    get clipboard() {
      return this._clipboard || (this._clipboard = new TabClipboard(this));
    }
    // Topmost element at a viewport point, through iframes.
    async elementAt(x, y) {
      let frame = this._mainFrame;
      let ox = 0;
      let oy = 0;
      for (let depth = 0; depth < 16; depth++) {
        const r = await frame._agent("elementAt", x - ox, y - oy, this._refMaxFor(frame));
        if (!r) return null;
        if (r.frame) {
          const child = await frame._contentFrame(r.frame);
          if (!child) return null;
          ox += r.box.x;
          oy += r.box.y;
          frame = child;
          continue;
        }
        this._noteRefMax(frame, r.max);
        const b = r.box;
        return { ref: this._prefixFor(frame) + r.ref, role: r.role, name: r.name, box: { x: b.x + ox, y: b.y + oy, width: b.width, height: b.height } };
      }
      return null;
    }
    // Keeps this tab open after a one-shot run.
    async keep() {
      this._kept = true;
      try {
        await this._session.call("tab.keep", { targetId: this._targetId });
      } catch (e) {
        if (driverErrorCode(e) !== "unsupported") throw e;
      }
    }
    url() {
      return this._url;
    }
    async title() {
      const info = await this._syncInfo();
      return info.title;
    }
    mainFrame() {
      return this._mainFrame;
    }
    frames() {
      return [this._mainFrame, ...this._frames.values()];
    }
    frame(nameOrOptions) {
      const opts = typeof nameOrOptions === "string" ? { name: nameOrOptions } : nameOrOptions || {};
      return this.frames().find((f) => (opts.name === undefined || f.name() === opts.name) && (opts.url === undefined || urlMatches("", f.url(), opts.url))) || null;
    }
    context() {
      const session = this._session;
      return {
        pages: () => [...session.pages.values()],
        cookies: (urls) => session.call("cookies.get", { urls: urls === undefined ? undefined : [].concat(urls) }),
        addCookies: (cookies) => session.call("cookies.set", { cookies }),
        clearCookies: (options) => this._clearCookies(options),
      };
    }
    // Playwright's clearCookies({ name, domain, path }), scoped like
    // session.storageState: driven tabs use the user's profile, so the driver
    // clears only the cookies of this tab's site (its registrable domain,
    // which the driver decides from the tab) and refuses { all: true } there;
    // a private or proxy store may be cleared whole. The driver matches
    // strings exactly; RegExp filters are matched here and each match is
    // cleared by its exact name, domain and path.
    async _clearCookies(options = {}) {
      const title = "browserContext.clearCookies";
      if (options === null || typeof options !== "object") throw new Error(`${title}: options: expected an object, got ${JSON.stringify(options)}`);
      const filters = {};
      for (const key of ["name", "domain", "path"]) {
        const v = options[key];
        if (v === undefined || v === null || v === "") continue;
        if (typeof v !== "string" && !isRegExp(v)) throw new Error(`${title}: ${key}: expected a string or a RegExp, got ${JSON.stringify(v)}`);
        filters[key] = v;
      }
      // A lazy page has no tab yet; its store is the session's default one.
      const scope = String(this._targetId).startsWith("lazy:") ? {} : { targetId: this._targetId };
      if (options.all) scope.all = true;
      // The driver refuses a tab with no site, and { all: true }, on the
      // user's profile, and knows which store this is.
      const clear = async (params) => {
        try {
          await this._session.call("cookies.clear", params);
        } catch (e) {
          if (driverErrorCode(e) !== "invalid") throw e;
          const message = String(e.message || "").replace(/^cookies\.clear: /, "");
          throw new Error(`${title}: ${message}`);
        }
      };
      if (!Object.values(filters).some(isRegExp)) {
        await clear({ ...scope, ...filters });
        return;
      }
      const matches = (cookie, key) => {
        const v = filters[key];
        if (v === undefined) return true;
        if (!isRegExp(v)) return cookie[key] === v;
        v.lastIndex = 0;
        return v.test(String(cookie[key]));
      };
      const cookies = await this._session.call("cookies.get", scope.targetId ? { targetId: scope.targetId } : {});
      for (const cookie of cookies) {
        if (!["name", "domain", "path"].every((key) => matches(cookie, key))) continue;
        await clear({ ...scope, name: cookie.name, domain: cookie.domain, path: cookie.path });
      }
    }
    opener() {
      return Promise.resolve(this._opener);
    }
    isClosed() {
      return this._closed;
    }
    async _navigate(method, params, options = {}) {
      if (options && options.waitUntil !== undefined && !["load", "domcontentloaded", "networkidle", "commit"].includes(options.waitUntil)) {
        throw new Error(`${method === "tab.navigate" ? "page.goto" : method === "tab.reload" ? "page.reload" : "page.goBack"}: waitUntil: expected one of (load|domcontentloaded|networkidle|commit), got ${JSON.stringify(options.waitUntil)}`);
      }
      const r = await this._session.call(method, {
        targetId: this._targetId,
        waitUntil: options.waitUntil || "load",
        timeoutMs: options.timeout !== undefined ? options.timeout : this._session.defaultNavigationTimeout,
        ...params,
      });
      await this._syncInfo();
      await this._refreshFrames().catch(() => {});
      return r;
    }
    async goto(url, options) {
      checkNavigableURL("page.goto", url);
      const r = await this._navigate("tab.navigate", { url }, options);
      const status = r && r.status;
      return status === undefined ? null : new Response(this, { url: this._url, status }, null);
    }
    async reload(options) {
      const recovering = this._crashed;
      let r;
      try {
        r = await this._navigate("tab.reload", {}, options);
      } catch (e) {
        // After a crash cmux reloads the tab itself when it shows it; that
        // load replacing ours is the recovery we asked for.
        if (!recovering || !/interrupted by another navigation/.test(String(e && e.message))) throw e;
        await this.waitForLoadState("load", options);
        await this._refreshFrames().catch(() => {});
        return null;
      }
      const status = r && r.status;
      return status === undefined ? null : new Response(this, { url: this._url, status }, null);
    }
    async goBack(options) {
      const r = await this._navigate("tab.history", { delta: -1 }, options);
      return r ? new Response(this, { url: this._url, status: 200 }, null) : null;
    }
    async goForward(options) {
      const r = await this._navigate("tab.history", { delta: 1 }, options);
      return r ? new Response(this, { url: this._url, status: 200 }, null) : null;
    }
    async content() {
      return this._mainFrame.content();
    }
    async setContent(html) {
      await this._mainFrame.evaluate((h) => {
        document.open();
        document.write(h);
        document.close();
      }, html);
    }
    evaluate(fn, arg) {
      return this._mainFrame.evaluate(fn, arg);
    }
    evaluateHandle(fn, arg) {
      return this._mainFrame.evaluate(fn, arg);
    }
    async addScriptTag(options = {}) {
      await this._mainFrame.evaluate((o) => {
        const s = document.createElement("script");
        if (o.url) s.src = o.url;
        if (o.content) s.textContent = o.content;
        if (o.type) s.type = o.type;
        document.head.appendChild(s);
      }, options);
    }
    async addStyleTag(options = {}) {
      await this._mainFrame.evaluate((o) => {
        const s = document.createElement(o.url ? "link" : "style");
        if (o.url) {
          s.rel = "stylesheet";
          s.href = o.url;
        } else s.textContent = o.content || "";
        document.head.appendChild(s);
      }, options);
    }
    setDefaultTimeout(ms) {
      this._session.defaultTimeout = ms;
    }
    setDefaultNavigationTimeout(ms) {
      this._session.defaultNavigationTimeout = ms;
    }
    async waitForLoadState(state = "load", options = {}) {
      if (!["load", "domcontentloaded", "networkidle", "commit"].includes(state)) {
        throw new Error(`page.waitForLoadState: state: expected one of (load|domcontentloaded|networkidle|commit)`);
      }
      const want = state === "networkidle" ? "load" : state;
      const rank = { commit: 0, domcontentloaded: 1, load: 2 };
      const timeout = options.timeout !== undefined ? options.timeout : this._session.defaultNavigationTimeout;
      await poll(this._session, timeout, "page.waitForLoadState", async () => {
        const info = await this._syncInfo();
        return { done: rank[info.loadState] >= rank[want] };
      });
    }
    async waitForURL(url, options = {}) {
      const timeout = options.timeout !== undefined ? options.timeout : this._session.defaultNavigationTimeout;
      await poll(this._session, timeout, "page.waitForURL", async () => {
        const info = await this._syncInfo();
        return { done: urlMatches(this._baseURL, info.url, url), log: `waiting for navigation to "${url}"` };
      });
      await this.waitForLoadState(options.waitUntil || "load", options);
    }
    async waitForNavigation(options = {}) {
      const start = this._url;
      await poll(this._session, options.timeout !== undefined ? options.timeout : this._session.defaultNavigationTimeout, "page.waitForNavigation", async () => {
        const info = await this._syncInfo();
        return { done: info.url !== start && (options.url === undefined || urlMatches("", info.url, options.url)) };
      });
      await this.waitForLoadState(options.waitUntil || "load", options);
      return null;
    }
    waitForTimeout(ms) {
      if (typeof ms !== "number" || !Number.isFinite(ms) || ms < 0) return Promise.reject(new Error(`waitForTimeout: timeout: expected a non-negative number, got ${JSON.stringify(ms)}`));
      return this._session.sleep(ms);
    }
    waitForFunction(fn, arg, options) {
      return this._mainFrame.waitForFunction(fn, arg, options);
    }
    waitForSelector(selector, options) {
      return this._mainFrame.waitForSelector(selector, options);
    }
    waitForEvent(event, optionsOrPredicate) {
      const options = typeof optionsOrPredicate === "function" ? { predicate: optionsOrPredicate } : optionsOrPredicate || {};
      const timeout = options.timeout !== undefined ? options.timeout : this._session.defaultTimeout;
      return new Promise((resolve, reject) => {
        let timer = null;
        const listener = async (value) => {
          try {
            if (options.predicate && !(await options.predicate(value))) return;
          } catch (e) {
            cleanup();
            reject(e);
            return;
          }
          cleanup();
          resolve(value);
        };
        const onClose = () => {
          if (event === "close") return;
          cleanup();
          reject(new Error("Target page, context or browser has been closed"));
        };
        const cleanup = () => {
          this.off(event, listener);
          this.off("close", onClose);
          if (timer) this._session.host.clearTimeout(timer);
        };
        this.on(event, listener);
        this.on("close", onClose);
        if (timeout) {
          timer = this._session.host.setTimeout(() => {
            cleanup();
            reject(new TimeoutError(`page.waitForEvent: Timeout ${timeout}ms exceeded while waiting for event "${event}"`));
          }, timeout);
        }
      });
    }
    waitForRequest(urlOrPredicate, options = {}) {
      const pred = typeof urlOrPredicate === "function" ? urlOrPredicate : (r) => urlMatches("", r.url(), urlOrPredicate);
      return this.waitForEvent("request", { ...options, predicate: pred });
    }
    waitForResponse(urlOrPredicate, options = {}) {
      const pred = typeof urlOrPredicate === "function" ? urlOrPredicate : (r) => urlMatches("", r.url(), urlOrPredicate);
      return this.waitForEvent("response", { ...options, predicate: pred });
    }
    async screenshot(options = {}) {
      if (options.type !== undefined && !["png", "jpeg"].includes(options.type)) {
        throw new Error(`page.screenshot: options.type: expected one of (png|jpeg)`);
      }
      if (options.clip !== undefined) {
        for (const k of ["x", "y", "width", "height"]) {
          if (typeof options.clip[k] !== "number" || !Number.isFinite(options.clip[k])) throw new Error(`page.screenshot: Expected options.clip.${k} to be a number`);
        }
        if (options.clip.width <= 0 || options.clip.height <= 0) throw new Error("page.screenshot: Expected options.clip.width and height to be positive");
      }
      if (options.quality !== undefined && (options.type || "png") === "png" && !(options.path && /\.jpe?g$/i.test(options.path))) {
        throw new Error("page.screenshot: options.quality is unsupported for the png screenshots");
      }
      const format = options.type || (options.path && /\.jpe?g$/i.test(options.path) ? "jpeg" : "png");
      const r = await this._session.call("tab.screenshot", {
        targetId: this._targetId,
        clip: options.clip,
        fullPage: !!options.fullPage,
        format,
        quality: options.quality,
      });
      const buf = Buffer.from(r.base64, "base64");
      if (options.path) await this._writeFile(options.path, buf);
      return buf;
    }
    async pdf(options = {}) {
      const r = await this._session.call("tab.pdf", {
        targetId: this._targetId,
        format: options.format,
        width: options.width,
        height: options.height,
        landscape: options.landscape,
        printBackground: options.printBackground,
        margin: options.margin,
      });
      const buf = Buffer.from(r.base64, "base64");
      if (options.path) await this._writeFile(options.path, buf);
      return buf;
    }
    async _writeFile(path, bytes) {
      if (!this._session.files) throw new Error("Writing files is not available in this session");
      await this._session.files.write(path, bytes);
    }
    // Writes this tab's content to a file and returns its path
    // (docs/browser-repl/README.md, Page additions): the page as Markdown by
    // default; `{ format }` exports a Google Docs, Sheets or Slides tab through
    // Google's export endpoint; `{ transcript: true }` writes a YouTube watch
    // page's captions as text. Requests carry this tab's cookies.
    async exportContent(options = {}) {
      if (options === null || typeof options !== "object") throw new Error(`page.exportContent: options: expected an object, got ${JSON.stringify(options)}`);
      const exporter = this._session.exporter;
      if (!exporter) throw new Error("page.exportContent is not supported in this session");
      const url = this.url();
      if (options.transcript) return exporter.youtubeTranscript(this, url, options);
      if (options.format !== undefined) return exporter.google(this, url, options);
      return exporter.markdown(this, options);
    }
    // The web content process that renders this tab (tests kill it to prove
    // crash recovery); null when the driver cannot tell.
    async _webProcessId() {
      const info = await this._syncInfo();
      return typeof info.webProcessId === "number" ? info.webProcessId : null;
    }
    async setViewportSize(size) {
      await this._session.call("tab.setViewport", { targetId: this._targetId, width: size.width, height: size.height });
      this._viewport = { width: size.width, height: size.height };
    }
    viewportSize() {
      return this._viewport || null;
    }
    async bringToFront() {
      await this._session.call("tab.bringToFront", { targetId: this._targetId });
    }
    // With runBeforeUnload the page may refuse through a beforeunload
    // dialog, so, as in Playwright, this does not wait for the tab to close.
    async close(options = {}) {
      if (this._closed) return;
      await this._session.call("tabs.close", { targetId: this._targetId, runBeforeUnload: !!options.runBeforeUnload });
      if (!options.runBeforeUnload) this._onClosed();
    }
    video() {
      return null;
    }
    // Selector-based shortcuts delegate to the main frame, as in Playwright.
    locator(selector, options) {
      return this._mainFrame.locator(selector, options);
    }
    getByRole(role, options) {
      return this._mainFrame.getByRole(role, options);
    }
    getByText(text, options) {
      return this._mainFrame.getByText(text, options);
    }
    getByLabel(text, options) {
      return this._mainFrame.getByLabel(text, options);
    }
    getByPlaceholder(text, options) {
      return this._mainFrame.getByPlaceholder(text, options);
    }
    getByAltText(text, options) {
      return this._mainFrame.getByAltText(text, options);
    }
    getByTitle(text, options) {
      return this._mainFrame.getByTitle(text, options);
    }
    getByTestId(testId) {
      return this._mainFrame.getByTestId(testId);
    }
    frameLocator(selector) {
      return this._mainFrame.frameLocator(selector);
    }
    $(selector) {
      return this._mainFrame.$(selector);
    }
    $$(selector) {
      return this._mainFrame.$$(selector);
    }
    $eval(selector, fn, arg) {
      return this._mainFrame.$eval(selector, fn, arg);
    }
    $$eval(selector, fn, arg) {
      return this._mainFrame.$$eval(selector, fn, arg);
    }
  }
  for (const name of ["click", "dblclick", "fill", "type", "press", "hover", "focus", "check", "uncheck", "selectOption",
    "setInputFiles", "dragAndDrop", "tap", "textContent", "innerText", "innerHTML", "getAttribute", "inputValue",
    "isVisible", "isHidden", "isEnabled", "isDisabled", "isChecked", "isEditable", "dispatchEvent"]) {
    Page.prototype[name] = function (...args) {
      return this._mainFrame[name](...args);
    };
  }

  const MIME = {
    txt: "text/plain", html: "text/html", htm: "text/html", css: "text/css", js: "text/javascript", json: "application/json",
    png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp", svg: "image/svg+xml",
    pdf: "application/pdf", csv: "text/csv", zip: "application/zip", mp4: "video/mp4", mp3: "audio/mpeg",
  };
  function mimeTypeFor(name) {
    const ext = String(name).split(".").pop().toLowerCase();
    return MIME[ext] || "application/octet-stream";
  }

  ns.core = {
    Session,
    Page,
    Frame,
    Locator,
    FrameLocator,
    ElementHandle,
    Keyboard,
    Mouse,
    TabClipboard,
    REF_PATTERN,
    Dialog,
    FileChooser,
    Download,
    ConsoleMessage,
    Request,
    Response,
    EventEmitter,
    TimeoutError,
    StaleRefError,
    Buffer,
    KEYS,
    splitKeyCombo,
    describeKey,
    functionSource,
    urlMatches,
    globToRegex,
    poll,
    base64Encode,
    base64Decode,
    utf8Encode,
    utf8Decode,
    mimeTypeFor,
    URL: URLImpl,
    URLSearchParams: URLSearchParamsImpl,
    MiniURL,
    MiniURLSearchParams,
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
