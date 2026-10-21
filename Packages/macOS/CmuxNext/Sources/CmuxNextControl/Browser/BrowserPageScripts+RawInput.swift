import Foundation

/// The page scripts of `browser.page.mouse|wheel|insert_text|key`: input at a viewport point or on
/// the focused element, as page events like `click` and `press` (the browser REPL keeps native
/// input). Daemon `browser.input.*` on a page the app draws runs these.
extension BrowserPageScripts {
    /// One mouse input at (`x`, `y`) in viewport CSS px. `kind` is `down`, `up`, `move` or
    /// `click` (a down, then an up). Every kind first moves the pointer there, with the
    /// over/out/enter/leave a person's pointer makes when it crosses elements. A down focuses the
    /// focusable element under it (left button); a right down sends `contextmenu`. An up after a
    /// down of the same button sends `click` (left, with `dblclick` for a count of 2) or
    /// `auxclick` to the nearest element that holds both targets.
    static func mouse(kind: String, x: Double, y: Double, button: String, clickCount: Int, modifiers: Set<String>) -> String {
        wrap(measure + modifierObject(modifiers) + """
        const x = \(number(x)), y = \(number(y)), kind = \(literal(kind)), buttonName = \(literal(button)), count = \(clickCount);
        const buttonIndex = { left: 0, middle: 1, right: 2, back: 3, forward: 4 }[buttonName];
        const buttonMask = { left: 1, middle: 4, right: 2, back: 8, forward: 16 }[buttonName];
        const target = document.elementFromPoint(x, y) || document.body || document.documentElement;
        if (!target) { return { error: 'No element at the point', code: 'not_found' }; }
        const state = window.__cmuxMouse || (window.__cmuxMouse = { over: null, down: null, buttons: 0 });
        const fire = (t, type, extra) => {
          if (!t || !t.isConnected) { return true; }
          const bubbles = !(type.endsWith('enter') || type.endsWith('leave'));
          const init = Object.assign({ bubbles, cancelable: true, composed: true, view: window, clientX: x, clientY: y,
            screenX: x + screenX, screenY: y + screenY, pointerId: 1, pointerType: 'mouse', isPrimary: true,
            buttons: state.buttons }, cmuxModifiers, extra || {});
          return t.dispatchEvent(type.startsWith('pointer') ? new PointerEvent(type, init) : new MouseEvent(type, init));
        };
        if (state.over !== target) {
          const old = state.over;
          for (const type of ['pointerout', 'mouseout', 'pointerleave', 'mouseleave']) { fire(old, type, { relatedTarget: target }); }
          for (const type of ['pointerover', 'mouseover', 'pointerenter', 'mouseenter']) { fire(target, type, { relatedTarget: old }); }
          state.over = target;
        }
        let ok = true;
        const steps = kind === 'click' ? ['down', 'up'] : [kind];
        for (const step of steps) {
          if (step === 'move') {
            fire(target, 'pointermove');
            ok = fire(target, 'mousemove') && ok;
          } else if (step === 'down') {
            state.buttons |= buttonMask;
            fire(target, 'pointerdown', { button: buttonIndex });
            const down = fire(target, 'mousedown', { button: buttonIndex, detail: count });
            ok = down && ok;
            if (down && buttonIndex === 0) {
              const focusable = target.closest ? target.closest('input,textarea,select,button,a:is([href]),[tabindex],[contenteditable]') : null;
              try {
                if (focusable) { focusable.focus({ preventScroll: true }); }
                else if (document.activeElement && document.activeElement !== document.body) { document.activeElement.blur(); }
              } catch (_) {}
            }
            state.down = { target, button: buttonIndex };
            if (buttonIndex === 2) { ok = fire(target, 'contextmenu', { button: 2, detail: 0 }) && ok; }
          } else {
            state.buttons &= ~buttonMask;
            fire(target, 'pointerup', { button: buttonIndex });
            ok = fire(target, 'mouseup', { button: buttonIndex, detail: count }) && ok;
            const pressed = state.down;
            state.down = null;
            if (pressed && pressed.button === buttonIndex) {
              let hit = pressed.target;
              while (hit && !(hit.contains && hit.contains(target))) { hit = hit.parentNode; }
              if (!hit || hit.nodeType !== 1) { hit = target; }
              if (buttonIndex === 0) {
                fire(hit, 'click', { button: 0, detail: count });
                if (count === 2) { fire(hit, 'dblclick', { button: 0, detail: 2 }); }
              } else {
                fire(hit, 'auxclick', { button: buttonIndex, detail: count });
              }
            }
          }
        }
        window.__cmuxAgentPointer = { x: Math.round(x), y: Math.round(y) };
        return { value: { kind, target: target.id || String(target.tagName || '').toLowerCase(), default_prevented: !ok }, at: cmuxAt(target) };
        """)
    }

    /// A wheel event at (`x`, `y`); when the page does not cancel it, the nearest box under the
    /// point that scrolls that way (else the page) scrolls by (`dx`, `dy`) CSS px.
    static func wheel(x: Double, y: Double, dx: Double, dy: Double, modifiers: Set<String>) -> String {
        wrap(modifierObject(modifiers) + """
        const x = \(number(x)), y = \(number(y)), dx = \(number(dx)), dy = \(number(dy));
        const target = document.elementFromPoint(x, y) || document.scrollingElement || document.body;
        const ok = target.dispatchEvent(new WheelEvent('wheel', Object.assign({ bubbles: true, cancelable: true, composed: true,
          view: window, clientX: x, clientY: y, deltaX: dx, deltaY: dy, deltaZ: 0, deltaMode: 0 }, cmuxModifiers)));
        let scroller = null;
        if (ok) {
          for (let el = target; el && el !== document.documentElement && el !== document.body; el = el.parentElement) {
            const style = getComputedStyle(el);
            const canY = dy !== 0 && /(auto|scroll|overlay)/.test(style.overflowY) && el.scrollHeight > el.clientHeight;
            const canX = dx !== 0 && /(auto|scroll|overlay)/.test(style.overflowX) && el.scrollWidth > el.clientWidth;
            if (canX || canY) { scroller = el; break; }
          }
          if (scroller) { scroller.scrollBy({ left: dx, top: dy, behavior: 'instant' }); }
          else { window.scrollBy({ left: dx, top: dy, behavior: 'instant' }); }
        }
        window.__cmuxAgentPointer = { x: Math.round(x), y: Math.round(y) };
        const box = scroller || document.scrollingElement || document.documentElement;
        return { value: { default_prevented: !ok, x: Math.round(box.scrollLeft), y: Math.round(box.scrollTop) } };
        """)
    }

    /// `text` into the focused text field or editable element (through shadow roots and
    /// same-origin frames), at its caret, replacing its selection, with `beforeinput` and `input`
    /// (`insertText`) as typing makes them. `{code: not_editable}` when nothing editable has focus.
    static func insertText(_ text: String) -> String {
        wrap(measure + editing + """
        const el = cmuxFocused();
        const text = \(literal(text));
        if (!cmuxEditable(el)) { return { error: 'not editable', code: 'not_editable' }; }
        cmuxInsert(el, text);
        return { value: { inserted: true }, at: cmuxAt(el) };
        """)
    }

    /// Whether the focused element (through shadow roots and same-origin frames) takes text:
    /// `{value: true, at}`, else `{code: not_editable}`.
    static let focusedEditable = wrap(measure + editing + """
        const el = cmuxFocused();
        if (!cmuxEditable(el)) { return { error: 'not editable', code: 'not_editable' }; }
        return { value: true, at: cmuxAt(el) };
        """)

    /// One key input on the focused element: `down` (keydown), `up` (keyup) or `press` (keydown,
    /// keypress for a printable key or Enter, keyup), with `modifiers` set on each event. A
    /// printable press with no control, alt or meta types its character into an editable focus,
    /// since a page-made key event types nothing itself.
    static func key(_ key: BrowserPressKey, kind: String, modifiers: Set<String>) -> String {
        wrap(measure + editing + modifierObject(modifiers) + """
        const target = cmuxFocused() || document.body || document.documentElement;
        const key = \(literal(key.key)), code = \(literal(key.code)), keyCode = \(key.keyCode), location = \(key.location), kind = \(literal(kind));
        const send = (type) => {
          const event = new KeyboardEvent(type, Object.assign({ key, code, location, repeat: false, isComposing: false,
            bubbles: true, cancelable: true, composed: true, view: window }, cmuxModifiers));
          try { Object.defineProperty(event, 'keyCode', { get() { return keyCode; } }); } catch (e) {}
          try { Object.defineProperty(event, 'which', { get() { return keyCode; } }); } catch (e) {}
          return target.dispatchEvent(event);
        };
        let ok = true, typed = false;
        if (kind === 'down') { ok = send('keydown'); }
        else if (kind === 'up') { ok = send('keyup'); }
        else {
          const printable = Array.from(key).length === 1 && !cmuxModifiers.ctrlKey && !cmuxModifiers.metaKey && !cmuxModifiers.altKey;
          const down = send('keydown');
          const press = down && (printable || key === 'Enter') ? send('keypress') : true;
          send('keyup');
          ok = down && press;
          if (ok && printable && cmuxEditable(target)) { cmuxInsert(target, key); typed = true; }
        }
        return { value: { key, kind, default_prevented: !ok, typed },
                 at: (target === document.body || target === document.documentElement) ? null : cmuxAt(target) };
        """)
    }

    /// `cmuxModifiers`: the event init fields of `modifiers`.
    private static func modifierObject(_ modifiers: Set<String>) -> String {
        """
        const cmuxModifiers = { shiftKey: \(modifiers.contains("shift")), ctrlKey: \(modifiers.contains("control")), \
        altKey: \(modifiers.contains("alt")), metaKey: \(modifiers.contains("meta")) };

        """
    }

    /// A finite number as a JavaScript literal.
    private static func number(_ value: Double) -> String { String(format: "%.3f", value) }

    /// `cmuxFocused()`, `cmuxEditable(el)` and `cmuxInsert(el, text)`: the focused element through
    /// shadow roots and same-origin frames, whether it takes text, and an insertion at its caret.
    private static let editing = """
        const cmuxFocused = () => {
          let el = document.activeElement;
          while (el) {
            if (el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
            if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
              let inner = null; try { inner = el.contentDocument; } catch (_) {}
              if (inner && inner.activeElement && inner.activeElement !== inner.body) { el = inner.activeElement; continue; }
            }
            break;
          }
          return (el && el !== document.body && el !== document.documentElement) || (el && el.isContentEditable) ? el : null;
        };
        const cmuxField = (el) => !!el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT'
          && ['button', 'submit', 'reset', 'checkbox', 'radio', 'file', 'image', 'color', 'range', 'hidden']
            .indexOf((el.type || 'text').toLowerCase()) === -1));
        const cmuxEditable = (el) => !!el && !el.disabled && !el.readOnly && (cmuxField(el) || el.isContentEditable);
        const cmuxInsert = (el, text) => {
          const doc = el.ownerDocument || document;
          const W = doc.defaultView || window;
          if (!cmuxField(el)) {
            const sel = W.getSelection();
            if (!sel.rangeCount || !el.contains(sel.anchorNode)) {
              const range = doc.createRange(); range.selectNodeContents(el); range.collapse(false);
              sel.removeAllRanges(); sel.addRange(range);
            }
            if (!doc.execCommand('insertText', false, text)) {
              if (!el.dispatchEvent(new W.InputEvent('beforeinput', { bubbles: true, cancelable: true, composed: true, inputType: 'insertText', data: text }))) { return; }
              const range = sel.getRangeAt(0); range.deleteContents(); range.insertNode(doc.createTextNode(text)); range.collapse(false);
              el.dispatchEvent(new W.InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
            }
            return;
          }
          if (!el.dispatchEvent(new W.InputEvent('beforeinput', { bubbles: true, cancelable: true, composed: true, inputType: 'insertText', data: text }))) { return; }
          let start = null, end = null;
          try { start = el.selectionStart; end = el.selectionEnd; } catch (_) {}
          const proto = el.tagName === 'TEXTAREA' ? W.HTMLTextAreaElement.prototype : W.HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
          const value = el.value || '';
          if (start === null || start === undefined) { setter.call(el, value + text); }
          else {
            setter.call(el, value.slice(0, start) + text + value.slice(end));
            try { el.setSelectionRange(start + text.length, start + text.length); } catch (_) {}
          }
          el.dispatchEvent(new W.InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
        };

        """
}
