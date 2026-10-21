// Page clipboard for tabs a REPL session created. Runs in the page's own
// world, at document start, in every frame, before the page's scripts.
//
// The host evaluates this file as an expression and calls it with `post`,
// a function that sends `{ items: [{ type, base64 }] }` to the tab's private
// clipboard (the one `page.clipboard` reads) and returns a promise that
// rejects when the tab has no session to hold it.
//
// The app also turns WebKit's asynchronous Clipboard API and its DOM paste
// requests off for these tabs, so a document this script does not reach has
// no `navigator.clipboard` and cannot paste. What this script adds:
//
// - `navigator.clipboard`, `Clipboard` and `ClipboardItem` whose writes go to
//   the tab's clipboard; a `ClipboardItem` whose data is a promise is written
//   once the promise settles. Writes need no transient activation: they
//   reach only this tab's clipboard, and WebKit resets the page's activation
//   after each script the driver evaluates, also between an agent click's
//   press and release, so the click handler of a real agent click has none.
//   Reads reject with NotAllowedError: the page never reads the agent's
//   clipboard through script (Meta+V gives it a paste event).
// - `document.execCommand("copy" | "cut")` fires the page's copy or cut
//   handlers with a DataTransfer and writes what they set, or the selection,
//   to the tab's clipboard; `execCommand("paste")` returns false. WebKit's
//   own commands, which use the system clipboard, never run from page script.
//   The command name is read with built-ins captured here, before the page's
//   scripts run, and only that string reaches WebKit: a page that replaces
//   `String`, `String.prototype.toLowerCase` or array methods cannot make a
//   name this script does not see as "copy" reach WebKit's Copy.
(function cmuxPageClipboard(post) {
  "use strict";
  const define = Object.defineProperty;
  const apply = Reflect.apply;
  const toPrimitiveString = String;
  const toLowerCase = String.prototype.toLowerCase;
  const NativeBlob = globalThis.Blob;
  const NativeDOMException = globalThis.DOMException;
  const NativeDataTransfer = globalThis.DataTransfer;
  const NativeClipboardEvent = globalThis.ClipboardEvent;
  const NativeDocument = globalThis.Document;
  const NativeNavigator = globalThis.Navigator;
  const NativeEventTarget = globalThis.EventTarget;
  const nativeExecCommand = NativeDocument && NativeDocument.prototype.execCommand;
  const blobArrayBuffer = NativeBlob && NativeBlob.prototype.arrayBuffer;
  const btoa = globalThis.btoa;
  const encoder = new TextEncoder();
  const encode = encoder.encode.bind(encoder);
  const fromCharCode = String.fromCharCode;

  const notAllowed = (message) => new NativeDOMException(message, "NotAllowedError");

  function base64(bytes) {
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      binary += apply(fromCharCode, null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(binary);
  }

  async function itemFrom(type, value) {
    const data = await value;
    if (NativeBlob && data instanceof NativeBlob) {
      return { type, base64: base64(new Uint8Array(await apply(blobArrayBuffer, data, []))) };
    }
    return { type, base64: base64(encode(String(data))) };
  }

  // ---- ClipboardItem and Clipboard

  const itemData = new WeakMap();

  class ClipboardItem {
    constructor(items, options) {
      if (items === null || typeof items !== "object") {
        throw new TypeError("ClipboardItem: the argument must be an object of types to data");
      }
      const entries = Object.entries(items);
      if (entries.length === 0) throw new TypeError("ClipboardItem: the argument has no types");
      const style = options && options.presentationStyle;
      itemData.set(this, { entries, presentationStyle: style === undefined ? "unspecified" : String(style) });
    }
    get types() {
      return Object.freeze(itemData.get(this).entries.map(([type]) => type));
    }
    get presentationStyle() {
      return itemData.get(this).presentationStyle;
    }
    async getType(type) {
      const entry = itemData.get(this).entries.find(([t]) => t === type);
      if (!entry) throw new NativeDOMException(`The type '${type}' was not found`, "NotFoundError");
      const data = await entry[1];
      return NativeBlob && data instanceof NativeBlob ? data : new NativeBlob([String(data)], { type });
    }
    static supports(type) {
      return ["text/plain", "text/html", "text/uri-list", "image/png"].includes(type) || /^web /.test(String(type));
    }
  }

  const constructing = Symbol("cmux clipboard");
  let clipboardInstance = null;

  class Clipboard extends NativeEventTarget {
    constructor(token) {
      if (token !== constructing) throw new TypeError("Illegal constructor");
      super();
    }
    readText() {
      return Promise.reject(notAllowed("Reading the clipboard is not allowed in this tab"));
    }
    read() {
      return Promise.reject(notAllowed("Reading the clipboard is not allowed in this tab"));
    }
    writeText(text) {
      return itemFrom("text/plain", String(text)).then((item) => post({ items: [item] })).then(() => undefined);
    }
    write(items) {
      const list = Array.from(items || []);
      return (async () => {
        const out = [];
        for (const item of list) {
          const data = itemData.get(item);
          if (!data) throw new TypeError("Clipboard.write: every item must be a ClipboardItem");
          for (const [type, value] of data.entries) out.push(await itemFrom(String(type), value));
        }
        await post({ items: out });
      })();
    }
  }

  function installClipboard() {
    if (!NativeNavigator || !NativeEventTarget) return;
    clipboardInstance = new Clipboard(constructing);
    try {
      define(NativeNavigator.prototype, "clipboard", {
        get() { return clipboardInstance; },
        enumerable: true,
        configurable: true,
      });
    } catch {}
    for (const [name, value] of [["Clipboard", Clipboard], ["ClipboardItem", ClipboardItem]]) {
      try {
        define(globalThis, name, { value, writable: true, configurable: true, enumerable: false });
      } catch {}
    }
  }

  // ---- execCommand("copy" | "cut")

  function selectedText(doc) {
    const active = doc.activeElement;
    if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA") && typeof active.selectionStart === "number") {
      return String(active.value).slice(active.selectionStart, active.selectionEnd);
    }
    const selection = doc.defaultView && doc.defaultView.getSelection();
    return selection ? String(selection) : "";
  }

  function eventTarget(doc) {
    const active = doc.activeElement;
    if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA")) return active;
    const selection = doc.defaultView && doc.defaultView.getSelection();
    const node = selection && selection.anchorNode;
    if (node) return node.nodeType === 1 ? node : node.parentElement || doc.body || doc.documentElement;
    return doc.body || doc.documentElement;
  }

  function copyOrCut(doc, type) {
    const win = doc && doc.defaultView;
    if (!win) return false;
    const target = eventTarget(doc);
    if (!target || !NativeDataTransfer || !NativeClipboardEvent) return false;
    const data = new NativeDataTransfer();
    const event = new NativeClipboardEvent(type, { bubbles: true, cancelable: true, composed: true, clipboardData: data });
    const cancelled = !target.dispatchEvent(event);
    let entries;
    if (cancelled) {
      entries = Array.from(data.types).filter((t) => t !== "Files").map((t) => [t, data.getData(t)]);
    } else {
      const text = selectedText(doc);
      entries = text ? [["text/plain", text]] : [];
      if (type === "cut" && text) apply(nativeExecCommand, doc, ["delete", false, ""]);
    }
    if (entries.length) {
      Promise.all(entries.map(([t, v]) => itemFrom(t, v)))
        .then((items) => post({ items }))
        .catch(() => {});
    }
    return true;
  }

  function installExecCommand() {
    if (!nativeExecCommand) return;
    const routed = new Proxy(nativeExecCommand, {
      apply(target, thisArg, args) {
        // Converted once: an object whose toString changes, or a replaced
        // String, cannot hand WebKit another name than the one checked.
        const command = args.length ? toPrimitiveString(args[0]) : "";
        if (typeof command !== "string") return false;
        const name = apply(toLowerCase, command, []);
        if (name === "copy" || name === "cut") {
          return copyOrCut(thisArg instanceof NativeDocument || (thisArg && thisArg.nodeType === 9) ? thisArg : null, name);
        }
        if (name === "paste") return false;
        // Only the checked string reaches WebKit, with the other arguments
        // read by index (no array method the page could replace).
        return apply(target, thisArg, [command, args[1], args[2]]);
      },
    });
    try {
      define(NativeDocument.prototype, "execCommand", { value: routed, writable: false, enumerable: true, configurable: false });
    } catch {}
  }

  installClipboard();
  installExecCommand();
})
