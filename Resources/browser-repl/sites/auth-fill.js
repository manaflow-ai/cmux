// Credential fill for sites.browserAuth.request, run by the app (not the
// REPL) after the user types into cmux's credential sheet: the body of an
// async function evaluated with WKWebView.callAsyncJavaScript in the app's
// own content world (not the agent world agent code can script) of the
// frame that holds the fields. Arguments: __fields ([{ id, type, marker }])
// and __values ({ id: value }). Only password, username and one-time-code
// inputs are filled, by the same rule as sites/browser-auth.js, and a
// password only into a password input. The result carries no value.
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
const found = [];
for (const f of __fields) {
  const el = document.querySelector('[data-cmux-auth="' + String(f.marker).replace(/["\\]/g, "") + '"]');
  if (!el) return { status: "page_changed", field: f.id };
  if (!(el instanceof HTMLInputElement) || el.disabled || el.readOnly) return { status: "locator_invalid", field: f.id };
  const kind = kindOf(el);
  if (!kind || (f.type === "password") !== (kind === "password")) return { status: "locator_invalid", field: f.id };
  found.push([f, el]);
}
for (const [f, el] of found) {
  const value = __values[f.id];
  if (typeof value !== "string") continue;
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
  el.focus();
  setter.call(el, value);
  el.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertReplacementText" }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  el.removeAttribute("data-cmux-auth");
}
return { status: "filled" };
