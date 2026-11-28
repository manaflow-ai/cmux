import Foundation

/// Page scripts for `browser.page.press|hover|scroll|scroll_into_view|select|check|uncheck`
/// (the old `cmux browser` input verbs). Failures return `{error, code}`;
/// `code` defaults to `not_found`.
extension BrowserPageScripts {
    /// The old app's pointer and mouse helpers: synthetic events with the
    /// fields React, Vue and plain handlers read.
    static let inputHelpers = """
        const center = (el) => { const r = el.getBoundingClientRect(); return { x: Math.floor(r.left + r.width / 2), y: Math.floor(r.top + r.height / 2) }; };
        const pointer = (el, type, c, buttons, bubbles) => { try { el.dispatchEvent(new PointerEvent(type, { bubbles: bubbles !== false, cancelable: true, composed: true, view: window, pointerId: 1, pointerType: 'mouse', isPrimary: true, button: 0, buttons, clientX: c.x, clientY: c.y, screenX: c.x, screenY: c.y })); } catch (e) {} };
        const mouse = (el, type, c, buttons, detail, bubbles) => { el.dispatchEvent(new MouseEvent(type, { bubbles: bubbles !== false, cancelable: true, composed: true, view: window, button: 0, buttons, detail: detail || 0, clientX: c.x, clientY: c.y, screenX: c.x, screenY: c.y })); };
        const hover = (el) => { const c = center(el);
          pointer(el, 'pointerover', c, 0); mouse(el, 'mouseover', c, 0);
          pointer(el, 'pointerenter', c, 0, false); mouse(el, 'mouseenter', c, 0, 0, false);
          pointer(el, 'pointermove', c, 0); mouse(el, 'mousemove', c, 0); };
        """

    static func hover(_ selector: String) -> String {
        wrap(inputHelpers + find(selector) + "el.scrollIntoView({ block: 'nearest', inline: 'nearest' }); hover(el); return { value: true };")
    }

    static func scrollIntoView(_ selector: String) -> String {
        wrap(find(selector) + "el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); return { value: true };")
    }

    /// Scrolls the element, or the page without a selector, by `dx`, `dy`.
    static func scroll(_ selector: String?, dx: Double, dy: Double) -> String {
        let by = "{ left: \(dx), top: \(dy), behavior: 'instant' }"
        guard let selector else {
            return wrap("window.scrollBy(\(by)); return { value: { x: window.scrollX, y: window.scrollY } };")
        }
        return wrap(find(selector) + """
        if (typeof el.scrollBy === 'function') { el.scrollBy(\(by)); } else { el.scrollLeft += \(dx); el.scrollTop += \(dy); }
        return { value: { x: el.scrollLeft, y: el.scrollTop } };
        """)
    }

    /// Sets the value through the native setter (so React sees it), then
    /// fires `input` and `change`, as the old `select` did.
    static func select(_ selector: String, value: String) -> String {
        wrap(find(selector) + """
        if (!('value' in el)) { return { error: 'Element is not a select or input: ' + raw, code: 'not_select' }; }
        const next = \(literal(value));
        if (el instanceof HTMLSelectElement && !Array.from(el.options).some((o) => o.value === next)) {
          return { error: 'No option with value ' + next, code: 'not_found' };
        }
        let setter = null;
        for (let p = Object.getPrototypeOf(el); p; p = Object.getPrototypeOf(p)) {
          const d = Object.getOwnPropertyDescriptor(p, 'value'); if (d && d.set) { setter = d.set; break; }
        }
        if (setter) { setter.call(el, next); } else { el.value = next; }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { value: el.value };
        """)
    }

    /// Clicks a checkbox or radio only when its state differs (a click is
    /// what frameworks map `onChange` to); a radio is unchecked through the
    /// native setter, since clicking only ever selects it.
    static func check(_ selector: String, _ desired: Bool) -> String {
        wrap(find(selector) + """
        // Every input has `checked`; only checkboxes and radios use it.
        if (!('checked' in el) || (el instanceof HTMLInputElement && el.type !== 'checkbox' && el.type !== 'radio')) { return { error: 'Element is not checkable: ' + raw, code: 'not_checkable' }; }
        if (el.disabled) { return { error: 'Element is disabled: ' + raw, code: 'disabled' }; }
        const desired = \(desired);
        el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
        if (typeof el.focus === 'function') { try { el.focus({ preventScroll: true }); } catch (e) {} }
        if (el.checked !== desired) {
          if (!desired && el.type === 'radio') {
            let setter = null;
            for (let p = Object.getPrototypeOf(el); p; p = Object.getPrototypeOf(p)) {
              const d = Object.getOwnPropertyDescriptor(p, 'checked'); if (d && d.set) { setter = d.set; break; }
            }
            if (setter) { setter.call(el, false); } else { el.checked = false; }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          } else {
            el.click();
          }
        }
        if (el.checked !== desired) { return { error: 'The page kept the element ' + (desired ? 'unchecked' : 'checked'), code: 'not_changed' }; }
        return { value: el.checked };
        """)
    }
}
