// sites.browserAuth: a secure sign-in handoff (reference B's
// browserAuth). The agent names the visible credential fields; cmux shows
// its own sheet on the browser window, naming the origin of the frame that
// holds them and labeling each field by its kind, the user types there, and
// the app fills the fields in the page (sites/auth-fill.js). Only password,
// username and one-time-code fields are filled, checked here and again by
// the app, and only in a tab this session opened under a domain policy
// that names the page's exact host (session.allowedDomains). No value passes through
// the REPL and the result never contains one; the app records each value
// as the tab's typed secret, so whatever the agent reads back from the page
// (values, results, captures) shows it masked. The page itself can read a
// filled field like any other.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL } = root.CmuxBrowserRepl.core;
  const TYPES = ["text", "email", "password", "tel", "number", "url"];
  // The credential kind of a field, or null. The app runs the same rule
  // (sites/auth-fill.js) before it fills anything.
  const CREDENTIAL_KIND = (el) => {
    if (!(el instanceof HTMLInputElement)) return null;
    const type = (el.getAttribute("type") || "text").toLowerCase();
    if (type === "password") return "password";
    if (!["text", "email", "tel", "number", "url", ""].includes(type)) return null;
    const tokens = String(el.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/);
    if (tokens.includes("one-time-code")) return "one-time-code";
    if (tokens.some((t) => ["username", "email", "webauthn"].includes(t)) || type === "email") return "username";
    const hint = `${el.getAttribute("name") || ""} ${el.id || ""}`;
    if (/otp|one.?time|passcode|verification.?code|2fa|mfa|totp/i.test(hint)) return "one-time-code";
    if (/user|login|e-?mail|account/i.test(hint)) return "username";
    return null;
  };

  // Whether `el` submits the form that holds the marked fields: a submit
  // button or input of that form, or, for Enter, one of the marked fields.
  // On the first check (before the sheet) the form is the first field's
  // and gets `formMarker`; on the second (right before the press, after the
  // fill removed the field markers) it must still be the form so marked.
  const SUBMITS_FORM = (el, a) => {
    const isSubmit = (x) => (x instanceof HTMLButtonElement && x.type === "submit") || (x instanceof HTMLInputElement && (x.type === "submit" || x.type === "image"));
    const form = el && el.form;
    if (!form) return false;
    if (a.markers) {
      const fields = a.markers.map((m) => document.querySelector('[data-cmux-auth="' + String(m).replace(/["\\]/g, "") + '"]'));
      if (!fields.every((f) => f && f.form === form)) return false;
      if (a.action === "press_enter" ? !fields.includes(el) : !isSubmit(el)) return false;
      if (form.hasAttribute("data-cmux-auth-form")) return false;
      form.setAttribute("data-cmux-auth-form", a.formMarker);
      return true;
    }
    if (form.getAttribute("data-cmux-auth-form") !== a.formMarker) return false;
    return a.action === "press_enter" ? el instanceof HTMLInputElement : isSubmit(el);
  };

  S.register(
    "browserAuth",
    (t) => ({
      // request(page?, { origin, fields: [{ id, label, type, autocomplete, required, selector }], submit: { selector, action: "click" | "press_enter" }, timeout })
      // -> { status: "submitted" | "cancelled" | "unavailable" | "expired" | "origin_changed" | "page_changed" | "locator_invalid" | "submission_failed", locator_error? }.
      // "submitted" means the fields were filled and any submit ran, not that sign-in succeeded.
      // submit must be a submit button or input of the form that holds the
      // fields ("click"), or one of the fields ("press_enter"); anything
      // else is locator_invalid with field_id "submit", before the sheet.
      async request(page, options) {
        if (!page || typeof page.url !== "function") {
          options = page;
          page = t.currentPage();
        }
        const o = options || {};
        const fields = o.fields;
        if (!Array.isArray(fields) || !fields.length || fields.length > 6) throw new S.SiteError("invalid", "browserAuth.request: fields: expected 1 to 6 credential fields");
        const ids = new Set();
        for (const f of fields) {
          if (!f || !/^[\w-]{1,40}$/.test(f.id || "") || ids.has(f.id)) throw new S.SiteError("invalid", `browserAuth.request: every field needs a unique id of letters, digits, _ or -; got ${JSON.stringify(f && f.id)}`);
          ids.add(f.id);
          if (typeof f.label !== "string" || !f.label.trim() || f.label.length > 60 || /[\r\n]/.test(f.label)) throw new S.SiteError("invalid", `browserAuth.request: field ${f.id}: label: expected a short noun phrase such as "Email" or "Password"`);
          if (!TYPES.includes(f.type)) throw new S.SiteError("invalid", `browserAuth.request: field ${f.id}: type: expected ${TYPES.join(", ")}, got ${JSON.stringify(f.type)}`);
          if (!f.selector) throw new S.SiteError("invalid", `browserAuth.request: field ${f.id}: selector is required`);
        }
        const current = new URL(page.url()).origin;
        if (!o.origin || o.origin !== current) return { status: "origin_changed" };
        const locate = (sel) => (typeof sel === "string" ? page.locator(sel) : sel);
        const marked = [];
        const formMarker = `form-${Math.floor(Math.random() * 1e12).toString(36)}`;
        let frameId;
        try {
          for (const f of fields) {
            const loc = locate(f.selector);
            if (!loc || typeof loc.count !== "function") throw new S.SiteError("invalid", `browserAuth.request: field ${f.id}: selector: expected a selector string or a locator`);
            if ((await loc.count()) !== 1) return { status: "locator_invalid", locator_error: { field_id: f.id, reason: "not_unique" } };
            if (!(await loc.isVisible())) return { status: "locator_invalid", locator_error: { field_id: f.id, reason: "not_user_visible" } };
            const tag = await loc.evaluate((el) => (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) && !el.disabled && !el.readOnly);
            if (!tag) return { status: "locator_invalid", locator_error: { field_id: f.id, reason: "not_editable_text_field" } };
            // Only credential fields: a password, username or one-time-code
            // input, by type, autocomplete or name. A requested password goes
            // only into a password field.
            const kind = await loc.evaluate(CREDENTIAL_KIND);
            if (!kind || (f.type === "password") !== (kind === "password")) return { status: "locator_invalid", locator_error: { field_id: f.id, reason: "not_credential_field" } };
            // The frame that holds the element (a frameLocator chain ends in a child frame).
            const resolved = typeof loc._resolveAll === "function" ? await loc._resolveAll() : null;
            const holder = resolved && resolved.frame;
            const fid = holder && holder !== page.mainFrame() && holder._id ? holder._id : undefined;
            if (marked.length && fid !== frameId) return { status: "locator_invalid", locator_error: { field_id: f.id, reason: "fields_in_different_frames" } };
            frameId = fid;
            const marker = `${f.id}-${Math.floor(Math.random() * 1e12).toString(36)}`;
            await loc.evaluate((el, m) => el.setAttribute("data-cmux-auth", m), marker);
            marked.push({ loc, field: f, marker });
          }
          // The control that submits, checked before the sheet opens: only
          // the submit control of the fields' own form, never another
          // control the user did not agree to press by filling the sheet.
          let submitLoc = null;
          const action = o.submit ? o.submit.action || "click" : null;
          if (o.submit) {
            if (action !== "click" && action !== "press_enter") throw new S.SiteError("invalid", `browserAuth.request: submit.action: expected "click" or "press_enter", got ${JSON.stringify(action)}`);
            submitLoc = locate(o.submit.selector);
            if (!submitLoc || typeof submitLoc.count !== "function") throw new S.SiteError("invalid", "browserAuth.request: submit.selector: expected a selector string or a locator");
            if ((await submitLoc.count()) !== 1) return { status: "locator_invalid", locator_error: { field_id: "submit", reason: "not_unique" } };
            const ok = await submitLoc.evaluate(SUBMITS_FORM, { markers: marked.map((m) => m.marker), action, formMarker }).catch(() => false);
            if (!ok) return { status: "locator_invalid", locator_error: { field_id: "submit", reason: "not_form_submit" } };
          }
          // The user should see the page they are signing in to under the sheet.
          await page.bringToFront().catch(() => {});
          let r;
          try {
            r = await t.session.call("auth.request", {
              targetId: page._targetId,
              frameId,
              origin: current,
              // The sheet waits this long for the user; keep it under the REPL call's --timeout.
              timeoutMs: o.timeout === undefined ? 110000 : o.timeout,
              fields: marked.map(({ field: f, marker }) => ({ id: f.id, label: f.label.trim(), type: f.type, autocomplete: f.autocomplete || null, required: f.required !== false, marker })),
            });
          } catch (e) {
            if (e && (e.code === "unsupported" || /unknown method|not supported/i.test(e.message || ""))) return { status: "unavailable" };
            throw e;
          }
          if (!r || r.status !== "filled") return { status: (r && r.status) || "unavailable" };
          if (submitLoc) {
            try {
              // Checked again right before the press: still one control,
              // still submitting the form marked before the sheet.
              if ((await submitLoc.count()) !== 1 || !(await submitLoc.evaluate(SUBMITS_FORM, { action, formMarker }))) return { status: "submission_failed" };
              if (action === "press_enter") await submitLoc.press("Enter");
              else await submitLoc.click();
            } catch (e) {
              return { status: "submission_failed" };
            }
          }
          return { status: "submitted" };
        } finally {
          for (const { loc } of marked) await loc.evaluate((el) => el.removeAttribute("data-cmux-auth")).catch(() => {});
          if (marked.length) await marked[0].loc.evaluate((el, m) => { for (const f of document.querySelectorAll("[data-cmux-auth-form]")) if (f.getAttribute("data-cmux-auth-form") === m) f.removeAttribute("data-cmux-auth-form"); }, formMarker).catch(() => {});
        }
      },
    }),
    { summary: "Secure sign-in: a cmux sheet collects credentials and fills the page; values reach the agent only masked" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
