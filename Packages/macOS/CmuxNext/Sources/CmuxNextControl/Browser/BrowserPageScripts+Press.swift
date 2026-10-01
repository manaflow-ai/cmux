import Foundation

/// `browser.page.press`: the old app's page-world key press (keydown,
/// keypress for printable keys and Enter, keyup), with Space activating
/// buttons and checkboxes and Enter submitting a single-line form field,
/// since synthetic events run no browser default action.
extension BrowserPageScripts {
    /// Presses `key` on the focused element, after focusing `selector` when given.
    static func press(_ key: BrowserPageKey, selector: String?) -> String {
        let target = selector.map { find($0) + "if (typeof el.focus === 'function') { el.focus(); }\nconst target = el;" }
            ?? "const target = document.activeElement || document.body || document.documentElement;\nif (!target) { return { error: 'No focused element' }; }"
        return wrap(target + """

        const key = \(literal(key.key)), code = \(literal(key.code)), keyCode = \(key.keyCode), location = \(key.location);
        const send = (type) => {
          const event = new KeyboardEvent(type, { key, code, location, repeat: false, isComposing: false, bubbles: true, cancelable: true, composed: true, view: window });
          try { Object.defineProperty(event, 'keyCode', { get() { return keyCode; } }); } catch (e) {}
          try { Object.defineProperty(event, 'which', { get() { return keyCode; } }); } catch (e) {}
          return target.dispatchEvent(event);
        };
        const down = send('keydown');
        const press = (key.length === 1 || key === 'Enter') ? send('keypress') : true;
        const up = send('keyup');
        if (key === ' ' && down && press && up && typeof target.matches === 'function'
            && target.matches('button,input[type=button],input[type=submit],input[type=reset],input[type=checkbox],input[type=radio]')) {
          try { target.click(); } catch (e) {}
        }
        if (key === 'Enter' && down && press && target.tagName === 'INPUT' && target.form) {
          const kinds = ['text','search','email','url','tel','password','number','date','datetime-local','month','week','time'];
          if (kinds.indexOf((target.type || 'text').toLowerCase()) !== -1) {
            const form = target.form;
            const submits = !!form.querySelector('input[type=submit],input[type=image],button[type=submit],button:not([type])');
            const fields = form.querySelectorAll(kinds.map((k) => 'input[type=' + k + ']').join(',') + ',input:not([type])');
            if (submits || fields.length === 1) {
              try { if (form.requestSubmit) { form.requestSubmit(); } else { form.submit(); } } catch (e) {}
            }
          }
        }
        return { value: { key, default_prevented: !(down && press && up) } };
        """)
    }
}
