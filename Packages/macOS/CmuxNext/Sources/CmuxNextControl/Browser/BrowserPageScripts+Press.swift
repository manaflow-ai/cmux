import Foundation

/// `browser.page.press`: the old app's page-world key press (keydown,
/// keypress for printable keys and Enter, keyup), with Space activating
/// buttons and checkboxes and Enter submitting a single-line form field,
/// since synthetic events run no browser default action.
extension BrowserPageScripts {
    /// DOM `key`, `code` and legacy `keyCode` for a W3C key name or one
    /// character. Nil for a name it does not know.
    static func keyEvent(_ name: String) -> (key: String, code: String, keyCode: Int)? {
        if let named = namedKeys[name] ?? namedKeys[name.lowercased()] { return named }
        guard name.count == 1, let scalar = name.unicodeScalars.first else { return nil }
        let upper = name.uppercased()
        if upper.count == 1, ("A"..."Z").contains(upper) { return (name, "Key" + upper, Int(upper.unicodeScalars.first?.value ?? 0)) }
        if ("0"..."9").contains(name) { return (name, "Digit" + name, Int(scalar.value)) }
        return (name, "", 0)
    }

    private static let namedKeys: [String: (key: String, code: String, keyCode: Int)] = {
        var keys: [String: (key: String, code: String, keyCode: Int)] = [
            "Enter": ("Enter", "Enter", 13), "Tab": ("Tab", "Tab", 9), "Escape": ("Escape", "Escape", 27),
            "Backspace": ("Backspace", "Backspace", 8), "Delete": ("Delete", "Delete", 46), " ": (" ", "Space", 32),
            "ArrowLeft": ("ArrowLeft", "ArrowLeft", 37), "ArrowUp": ("ArrowUp", "ArrowUp", 38),
            "ArrowRight": ("ArrowRight", "ArrowRight", 39), "ArrowDown": ("ArrowDown", "ArrowDown", 40),
            "Home": ("Home", "Home", 36), "End": ("End", "End", 35), "PageUp": ("PageUp", "PageUp", 33),
            "PageDown": ("PageDown", "PageDown", 34),
        ]
        for n in 1...12 { keys["F\(n)"] = ("F\(n)", "F\(n)", 111 + n) }
        for (alias, name) in [("Space", " "), ("Esc", "Escape"), ("Return", "Enter"), ("Left", "ArrowLeft"), ("Up", "ArrowUp"),
                              ("Right", "ArrowRight"), ("Down", "ArrowDown")] {
            keys[alias] = keys[name]
        }
        for (name, value) in keys { keys[name.lowercased()] = value }
        return keys
    }()

    /// Presses `key` on the focused element, after focusing `selector` when given.
    static func press(_ key: (key: String, code: String, keyCode: Int), selector: String?) -> String {
        let target = selector.map { find($0) + "if (typeof el.focus === 'function') { el.focus(); }\nconst target = el;" }
            ?? "const target = document.activeElement || document.body || document.documentElement;\nif (!target) { return { error: 'No focused element' }; }"
        return wrap(target + """

        const key = \(literal(key.key)), code = \(literal(key.code)), keyCode = \(key.keyCode);
        const send = (type) => {
          const event = new KeyboardEvent(type, { key, code, repeat: false, isComposing: false, bubbles: true, cancelable: true, composed: true, view: window });
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
