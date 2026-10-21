// Credential fill for sites.browserAuth.request, run by the app (not the
// REPL): the body of an async function evaluated with
// WKWebView.callAsyncJavaScript in the app's own content world (not the
// agent world agent code can script) of the frame that holds the fields.
// Arguments: __phase ("bind" | "fill"), __binding (a token the app made for
// this request), __fields ([{ id, type, marker }]), __values ({ id: value })
// and __origin, the origin the sheet showed the user.
//
// "bind" runs when the sheet is requested, before the user types: it takes
// the one element that holds each field's marker, and the document, and
// keeps them under __binding in this world's global, which no page or agent
// script reaches (and which a new document does not have). "fill" runs after
// the user presses Fill and writes only into those elements, and only when
// the frame still shows that document, each element is still in it and is
// still the only one with its marker: another session driving the tab, or
// the page, can move a marker, copy it to another element or load another
// same-origin document while the sheet is up, and any of that fills nothing
// (page_changed). WebKit's frame record is taken before the sheet opens, and
// the frame may load another origin's document while the user types, so the
// document that receives the values is checked here, at fill time: a
// different origin gets nothing (origin_changed). Only password, username
// and one-time-code inputs are filled, by the same rule as
// sites/browser-auth.js, and a password only into a password input. "bind"
// answers each bound element's kind, which the sheet shows as the field's
// label. The result carries no value. The app records the values as the
// tab's typed secrets before "fill", so every session's reads of the page
// get them masked.
//
// Agent code can call auth.request itself and mark any element, so the
// helper's visibility check is not a guard: "bind" and "fill" take only a
// field the user can see. It is shown (no display:none, no opacity 0 on it
// or an ancestor, visibility visible, not inert) and at least MIN_SIDE CSS
// pixels each way; at fill time also focusable (it becomes the focused
// element) and, scrolled into view by that focus, on screen and not
// covered (the frame's hit test at the middle of its visible part finds
// it). A field that fails gets nothing (locator_invalid).
if (typeof __origin !== "string" || location.origin !== __origin) return { status: "origin_changed" };
const kindOf = (el) => {
  if (!(el instanceof HTMLInputElement)) return null;
  const type = (el.getAttribute("type") || "text").toLowerCase();
  if (type === "password") return "password";
  if (!["text", "email", "tel", "number", "url", ""].includes(type)) return null;
  const tokens = String(el.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/);
  if (tokens.includes("one-time-code")) return "one-time-code";
  if (tokens.some((t) => ["username", "email", "webauthn"].includes(t)) || type === "email") return "username";
  const hint = (el.getAttribute("name") || "") + " " + (el.id || "");
  if (/otp|one.?time|passcode|verification.?code|2fa|mfa|totp/i.test(hint)) return "one-time-code";
  if (/user|login|e-?mail|account/i.test(hint)) return "username";
  return null;
};
const MIN_SIDE = 4;
const parentOf = (n) => n.parentElement || (n.parentNode instanceof ShadowRoot ? n.parentNode.host : null);
const shown = (el) => {
  if (el.inert) return false;
  for (let n = el; n; n = parentOf(n)) {
    const cs = getComputedStyle(n);
    if (n.inert || cs.display === "none" || Number(cs.opacity) === 0) return false;
  }
  if (getComputedStyle(el).visibility !== "visible") return false;
  const r = el.getBoundingClientRect();
  return r.width >= MIN_SIDE && r.height >= MIN_SIDE;
};
const reachable = (el) => {
  el.focus();
  const root = el.getRootNode();
  if (root.activeElement !== el) return false;
  const r = el.getBoundingClientRect();
  const left = Math.max(r.left, 0);
  const top = Math.max(r.top, 0);
  const right = Math.min(r.right, document.documentElement.clientWidth || innerWidth);
  const bottom = Math.min(r.bottom, document.documentElement.clientHeight || innerHeight);
  if (right - left < 1 || bottom - top < 1) return false;
  return root.elementFromPoint((left + right) / 2, (top + bottom) / 2) === el;
};
const markedWith = (marker) => document.querySelectorAll('[data-cmux-auth="' + String(marker).replace(/["\\]/g, "") + '"]');
const usable = (f, el) => {
  if (!(el instanceof HTMLInputElement) || el.disabled || el.readOnly || !shown(el)) return false;
  const kind = kindOf(el);
  return !!kind && (f.type === "password") === (kind === "password");
};
if (typeof __binding !== "string" || !__binding) return { status: "page_changed" };
const bindings = Object.prototype.hasOwnProperty.call(globalThis, "__cmuxAuthBindings")
  ? globalThis.__cmuxAuthBindings
  : Object.defineProperty(globalThis, "__cmuxAuthBindings", { value: new Map() }).__cmuxAuthBindings;
if (__phase === "bind") {
  const elements = [];
  for (const f of __fields) {
    const all = markedWith(f.marker);
    if (all.length !== 1) return { status: "page_changed", field: f.id };
    if (!usable(f, all[0])) return { status: "locator_invalid", field: f.id };
    elements.push(all[0]);
  }
  bindings.set(__binding, { document, origin: location.origin, elements });
  // The sheet labels each field by this kind, never by the agent's label.
  return { status: "bound", kinds: elements.map(kindOf) };
}
if (__phase !== "fill") return { status: "page_changed" };
const bound = bindings.get(__binding);
bindings.delete(__binding);
if (!bound || bound.document !== document || bound.origin !== location.origin || bound.elements.length !== __fields.length) return { status: "page_changed" };
const found = [];
for (const [index, f] of __fields.entries()) {
  const el = bound.elements[index];
  const all = markedWith(f.marker);
  if (!el.isConnected || el.ownerDocument !== document || all.length !== 1 || all[0] !== el) return { status: "page_changed", field: f.id };
  if (!usable(f, el) || !reachable(el)) return { status: "locator_invalid", field: f.id };
  found.push([f, el]);
}
for (const [f, el] of found) {
  const value = __values[f.id];
  if (typeof value !== "string") continue;
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
  // The page saw the fields before this one change: check this one again.
  if (!usable(f, el) || !reachable(el)) return { status: "locator_invalid", field: f.id };
  setter.call(el, value);
  el.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertReplacementText" }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  el.removeAttribute("data-cmux-auth");
}
return { status: "filled" };
