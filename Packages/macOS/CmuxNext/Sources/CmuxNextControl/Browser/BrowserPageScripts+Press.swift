import Foundation

/// `browser.page.press`: the old app's page-world key press (keydown,
/// keypress for printable keys and Enter, keyup), with Space activating
/// buttons and checkboxes and Enter submitting a single-line form field,
/// since synthetic events run no browser default action.
extension BrowserPageScripts {
    /// Presses `key` on the focused element, after focusing `selector` when given.
    static func press(_ key: BrowserPressKey, selector: String?) -> String {
        let target = selector.map { find($0) + "if (typeof el.focus === 'function') { el.focus(); }\nconst target = el;" }
            ?? measure + "const target = document.activeElement || document.body || document.documentElement;\nif (!target) { return { error: 'No focused element' }; }"
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
            && (target.tagName === 'BUTTON' || (target.tagName === 'INPUT'
              && ['button', 'submit', 'reset', 'checkbox', 'radio'].indexOf((target.type || '').toLowerCase()) !== -1))) {
          try { target.click(); } catch (e) {}
        }
        if (key === 'Enter' && down && press && target.tagName === 'INPUT' && target.form) {
          const kinds = ['text','search','email','url','tel','password','number','date','datetime-local','month','week','time'];
          if (kinds.indexOf((target.type || 'text').toLowerCase()) !== -1) {
            const form = target.form;
            // A button's type defaults to submit; an input's type reads as text when missing.
            const submits = Array.from(form.querySelectorAll('input, button')).some((el) => el.tagName === 'BUTTON'
              ? el.type === 'submit' : (el.type === 'submit' || el.type === 'image'));
            const fields = Array.from(form.querySelectorAll('input')).filter((el) => kinds.indexOf((el.type || 'text').toLowerCase()) !== -1);
            if (submits || fields.length === 1) {
              try { if (form.requestSubmit) { form.requestSubmit(); } else { form.submit(); } } catch (e) {}
            }
          }
        }
        return { value: { key, default_prevented: !(down && press && up) },
                 at: (target === document.body || target === document.documentElement) ? null : cmuxAt(target) };
        """)
    }
}
