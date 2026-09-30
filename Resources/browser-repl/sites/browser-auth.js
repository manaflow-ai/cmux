// sites.browserAuth: a secure sign-in handoff (ChatGPT for Chrome's
// browserAuth). The agent names the visible credential fields; cmux shows
// its own sheet on the browser window, the user types there, and the app
// fills the fields in the page (sites/auth-fill.js). No value passes through
// the REPL, and the result never contains one.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL } = root.CmuxBrowserRepl.core;
  const TYPES = ["text", "email", "password", "tel", "number", "url"];

  S.register(
    "browserAuth",
    (t) => ({
      // request(page?, { origin, fields: [{ id, label, type, autocomplete, required, selector }], submit: { selector, action: "click" | "press_enter" }, timeout })
      // -> { status: "submitted" | "cancelled" | "unavailable" | "expired" | "origin_changed" | "page_changed" | "locator_invalid" | "submission_failed", locator_error? }.
      // "submitted" means the fields were filled and any submit ran, not that sign-in succeeded.
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
        let frameId;
        try {
          for (const f of fields) {
            const loc = locate(f.selector);
            if (!loc || typeof loc.count !== "function") throw new S.SiteError("invalid", `browserAuth.request: field ${f.id}: selector: expected a selector string or a locator`);
            if ((await loc.count()) !== 1) return { status: "locator_invalid", locator_error: { field_id: f.id, reason: "not_unique" } };
            if (!(await loc.isVisible())) return { status: "locator_invalid", locator_error: { field_id: f.id, reason: "not_user_visible" } };
            const tag = await loc.evaluate((el) => (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) && !el.disabled && !el.readOnly);
            if (!tag) return { status: "locator_invalid", locator_error: { field_id: f.id, reason: "not_editable_text_field" } };
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
          if (o.submit) {
            try {
              const s = locate(o.submit.selector);
              if ((o.submit.action || "click") === "press_enter") await s.press("Enter");
              else await s.click();
            } catch (e) {
              return { status: "submission_failed" };
            }
          }
          return { status: "submitted" };
        } finally {
          for (const { loc } of marked) await loc.evaluate((el) => el.removeAttribute("data-cmux-auth")).catch(() => {});
        }
      },
    }),
    { summary: "Secure sign-in: a cmux sheet collects credentials and fills the page; values never reach the agent" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
