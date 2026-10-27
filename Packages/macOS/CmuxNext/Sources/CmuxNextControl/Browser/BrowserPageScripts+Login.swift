import Foundation

/// Page scripts for `browser.page.fill_login` (cmux https://github.com/manaflow-ai/cmux/issues/25830):
/// the app fills a login from the person's Secure Store into the page, so the agent never sees it.
///
/// Fields: the visible password field (`autocomplete="current-password"` first, never a lone
/// `new-password` sign-up field), and the text, email or phone field before it in the same form
/// that reads most like a username (`autocomplete` username or email, `type=email`, a name, id,
/// label or placeholder saying user, email, login, account or phone; search, code and address
/// fields never). A two-step login shows only the username: it is filled alone when it says it
/// is one. The document is walked with its open shadow roots and same-origin frames, in tree order.
extension BrowserPageScripts {
    /// The attribute the fill leaves on the last field it filled, for ``submitLogin``.
    static let loginMark = "data-cmux-login"

    /// `cmuxLoginShown(el)` and `cmuxLoginFields()` → `{user, pass}` (either may be null).
    static let loginFields = """
        const cmuxLoginAll = () => { const out = []; const walk = (root, depth) => { if (depth > 8 || !root) return; let nodes = []; try { nodes = root.querySelectorAll('*'); } catch (_) { return; } \
        for (const n of nodes) { if (n.tagName === 'INPUT') out.push(n); if (n.shadowRoot) walk(n.shadowRoot, depth + 1); \
        if (n.tagName === 'IFRAME' || n.tagName === 'FRAME') { let d = null; try { d = n.contentDocument; } catch (_) {} if (d) walk(d, depth + 1); } } }; walk(document, 0); return out; };
        const cmuxLoginShown = (e) => { if (!e || e.disabled || e.readOnly || String(e.type || '').toLowerCase() === 'hidden') return false; \
        let r = null; try { r = e.getBoundingClientRect(); } catch (_) { return false; } if (!r || r.width < 4 || r.height < 4) return false; \
        let s = null; try { s = (e.ownerDocument.defaultView || window).getComputedStyle(e); } catch (_) {} \
        return !s || (s.visibility !== 'hidden' && s.display !== 'none' && parseFloat(s.opacity || '1') > 0.05); };
        const cmuxLoginFields = () => {
          const all = cmuxLoginAll().filter(cmuxLoginShown);
          const auto = (e) => String(e.getAttribute('autocomplete') || '').toLowerCase().split(/\\s+/).filter(Boolean);
          const kind = (e) => String(e.type || 'text').toLowerCase();
          const pws = all.filter((e) => kind(e) === 'password');
          const pass = pws.find((e) => auto(e).indexOf('current-password') !== -1) || pws.find((e) => auto(e).indexOf('new-password') === -1) || null;
          const words = (e) => [e.name, e.id, e.getAttribute('aria-label'), e.getAttribute('placeholder')].map((v) => String(v || '')).join(' ');
          const never = ['one-time-code', 'postal-code', 'street-address', 'address-line1', 'name', 'given-name', 'family-name', 'cc-number', 'search'];
          const score = (e) => {
            if (['text', 'email', 'tel'].indexOf(kind(e)) === -1) return -1;
            const a = auto(e), w = words(e);
            if (a.some((t) => never.indexOf(t) !== -1)) return -1;
            if (/search|query|captcha|otp|one.?time|verification|coupon|promo|zip|postal|first.?name|last.?name|full.?name/i.test(w)) return -1;
            let s = 0;
            if (a.indexOf('username') !== -1) s += 10; else if (a.indexOf('email') !== -1) s += 8; else if (a.indexOf('tel') !== -1) s += 3;
            if (kind(e) === 'email') s += 6;
            if (/user|e-?mail|login|log.?in|account|identifier|phone|handle|sign.?in/i.test(w)) s += 4;
            return s;
          };
          let user = null, best = -1;
          if (pass) {
            // The field before the password, in its form; the closest of the best wins.
            const at = all.indexOf(pass);
            all.forEach((e, i) => { if (i >= at || e.form !== pass.form) return; const s = score(e); if (s < 0 || (!pass.form && s === 0)) return; if (s >= best) { best = s; user = e; } });
          } else {
            // A two-step login's first step: only a field that says it takes a username.
            all.forEach((e) => { const s = score(e); if (s >= 4 && s > best) { best = s; user = e; } });
          }
          return { user, pass };
        };
        """

    /// Fills `username` and `password` into the login fields of a page on `host` (the top
    /// document's host, checked again here so a page that navigated away gets nothing). Answers
    /// `{value: {username, password, reason?}, at}`: which fields it filled (booleans only, never
    /// a value) and the last field's rect, always marked secret. The values ride only in this
    /// script; nothing echoes them.
    static func fillLogin(host: String, username: String, password: String) -> String {
        wrap(measure + loginFields + """
        if (String(location.hostname || '').toLowerCase() !== \(literal(host.lowercased()))) {
          return { value: { username: false, password: false, reason: 'navigated' } };
        }
        const found = cmuxLoginFields();
        if (!found.user && !found.pass) { return { value: { username: false, password: false, reason: 'no_login_field' } }; }
        const put = (el, next) => {
          try { el.focus(); } catch (_) {}
          const W = (el.ownerDocument && el.ownerDocument.defaultView) || window;
          const d = Object.getOwnPropertyDescriptor(W.HTMLInputElement.prototype, 'value');
          if (d && d.set) { d.set.call(el, next); } else { el.value = next; }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        if (found.user) { put(found.user, \(literal(username))); }
        if (found.pass) { put(found.pass, \(literal(password))); }
        for (const e of cmuxLoginAll()) { try { e.removeAttribute('\(loginMark)'); } catch (_) {} }
        const last = found.pass || found.user;
        last.setAttribute('\(loginMark)', '');
        const at = cmuxAt(last);
        if (at) { at.secret = true; }
        return { value: { username: !!found.user, password: !!found.pass }, at };
        """)
    }

    /// Submits the form of the field ``fillLogin(host:username:password:)`` filled last, in a
    /// later task than the fill so a framework sees the new values first: its sign-in (or next)
    /// submit button, else the form itself, else a sign-in button near the field, else Enter on
    /// the field. Answers `{value: true}` when it pressed or submitted something.
    static let submitLogin = wrap(deepQuery + loginFields + """
        const el = cmuxDeep(document, '[\(loginMark)]', 0);
        if (!el) { return { value: false }; }
        el.removeAttribute('\(loginMark)');
        const label = (b) => String(b.innerText || b.value || b.getAttribute('aria-label') || '').trim();
        const go = /^(sign ?in|sign ?on|log ?in|login|continue|next|submit)\\b/i;
        const submits = (b) => b.tagName === 'BUTTON' ? String(b.getAttribute('type') || 'submit').toLowerCase() === 'submit'
          : ['submit', 'image'].indexOf(String(b.type || '').toLowerCase()) !== -1;
        const form = el.form;
        if (form) {
          const buttons = Array.from(form.querySelectorAll('button, input')).filter((b) => submits(b) && cmuxLoginShown(b));
          const button = buttons.find((b) => go.test(label(b))) || buttons[0];
          if (button) { button.click(); return { value: true }; }
          try { if (form.requestSubmit) { form.requestSubmit(); } else { form.submit(); } return { value: true }; } catch (_) {}
        }
        const root = (el.getRootNode && el.getRootNode().querySelectorAll) ? el.getRootNode() : el.ownerDocument;
        const near = Array.from(root.querySelectorAll('button, [role=button], [type=submit]')).find((b) => cmuxLoginShown(b) && go.test(label(b)));
        if (near) { near.click(); return { value: true }; }
        const key = (type) => el.dispatchEvent(new KeyboardEvent(type, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true }));
        try { el.focus(); } catch (_) {}
        key('keydown'); key('keypress'); key('keyup');
        return { value: false };
        """)
}
