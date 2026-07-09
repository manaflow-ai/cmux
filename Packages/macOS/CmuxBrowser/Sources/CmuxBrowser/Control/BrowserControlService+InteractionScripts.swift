import Foundation

/// JavaScript builders for the browser user-action commands (`browser.click`,
/// `dblclick`, `hover`, `focus`, `type`, `fill`, `press`, `keydown`, `keyup`,
/// `check`/`uncheck`, `select`, `scroll`, `scroll_into_view`).
///
/// Every string returned here is byte-identical to the script the corresponding
/// `v2Browser*` method previously assembled inline in `TerminalController`; only
/// the assembly moved into this package, mirroring the `find.*` locator builders
/// in ``BrowserControlService/findScript(finderBody:)`` and friends.
///
/// The owning `@MainActor` controller (app side) still owns the panel
/// resolution, the WebKit evaluation seam, the retry/wait-for-condition loop, the
/// post-action snapshot, the element-not-found diagnostics, and the per-surface
/// element-ref state; it forwards into these pure builders for the script text,
/// so the RPC wire output is unchanged.
extension BrowserControlService {
    /// Shared input-event helpers injected at the top of an action snippet.
    ///
    /// Synthetic (untrusted) events do not run native default actions, and many
    /// frameworks/libraries listen on the full pointer + mouse sequence (not just
    /// `click`) or need legacy `KeyboardEvent` fields (`keyCode`/`which`/`code`).
    /// These helpers reproduce a real user gesture so React, Vue, Svelte, Angular,
    /// Solid, and vanilla handlers all fire. Define them once at the top of an
    /// injected snippet, then call `__cmuxClick(el)`, `__cmuxHover(el)`,
    /// `__cmuxSetChecked(el, desired)`, and `__cmuxKey(t,type,key)`.
    ///
    /// Byte-identical to the former `TerminalController.browserInputHelpers`.
    public static let inputHelpers = """
    function __cmuxCenter(el){const r=el.getBoundingClientRect();return {x:Math.floor(r.left+Math.min(r.width,r.width/2)),y:Math.floor(r.top+Math.min(r.height,r.height/2))};}
    function __cmuxPointer(el,type,c,buttons,bubbles){try{el.dispatchEvent(new PointerEvent(type,{bubbles:(bubbles===false?false:true),cancelable:true,composed:true,view:window,pointerId:1,pointerType:'mouse',isPrimary:true,button:0,buttons:buttons,clientX:c.x,clientY:c.y,screenX:c.x,screenY:c.y}));}catch(e){}}
    function __cmuxMouse(el,type,c,buttons,detail,bubbles){el.dispatchEvent(new MouseEvent(type,{bubbles:(bubbles===false?false:true),cancelable:true,composed:true,view:window,button:0,buttons:buttons,detail:detail||0,clientX:c.x,clientY:c.y,screenX:c.x,screenY:c.y}));}
    function __cmuxClick(el){const c=__cmuxCenter(el);
      __cmuxPointer(el,'pointerover',c,0);__cmuxMouse(el,'mouseover',c,0);
      __cmuxPointer(el,'pointerenter',c,0,false);__cmuxMouse(el,'mouseenter',c,0,0,false);
      __cmuxPointer(el,'pointermove',c,0);__cmuxMouse(el,'mousemove',c,0);
      __cmuxPointer(el,'pointerdown',c,1);__cmuxMouse(el,'mousedown',c,1,1);
      if(typeof el.focus==='function'){try{el.focus({preventScroll:true});}catch(e){try{el.focus();}catch(e2){}}}
      __cmuxPointer(el,'pointerup',c,0);__cmuxMouse(el,'mouseup',c,0,1);
      if(typeof el.click==='function'){el.click();}else{__cmuxMouse(el,'click',c,0,1);}
    }
    function __cmuxHover(el){const c=__cmuxCenter(el);
      __cmuxPointer(el,'pointerover',c,0);__cmuxMouse(el,'mouseover',c,0);
      __cmuxPointer(el,'pointerenter',c,0,false);__cmuxMouse(el,'mouseenter',c,0,0,false);
      __cmuxPointer(el,'pointermove',c,0);__cmuxMouse(el,'mousemove',c,0);
    }
    function __cmuxSetChecked(el,desired){
      // A click event runs the checkbox/radio activation behavior (it TOGGLES a checkbox / SELECTS a
      // radio) even when dispatched, and is also what React maps onChange to. So the correct way to
      // reach a target state is to click only when it differs; that fires input + change + (React)
      // onChange and leaves checked === desired. Setting el.checked directly does not update React's
      // controlled state and a separate click would toggle it back.
      if(el.checked===desired) return;
      // A radio cannot be turned OFF by clicking (clicking a radio only ever selects it). For that
      // one case set the property directly via the native setter and notify listeners.
      if(desired===false && el.type==='radio'){
        let ns=null;
        for(let p=Object.getPrototypeOf(el);p;p=Object.getPrototypeOf(p)){
          const d=Object.getOwnPropertyDescriptor(p,'checked'); if(d&&d.set){ns=d.set;break;}
        }
        if(ns){ns.call(el,false);}else{el.checked=false;}
        el.dispatchEvent(new Event('input',{bubbles:true}));
        el.dispatchEvent(new Event('change',{bubbles:true}));
        return;
      }
      if(typeof el.click==='function'){el.click();}
      else {const c=__cmuxCenter(el); __cmuxMouse(el,'click',c,0,1);}
    }
    function __cmuxKeyMeta(key){
      const map={Enter:[13,'Enter'],Tab:[9,'Tab'],Backspace:[8,'Backspace'],Delete:[46,'Delete'],Escape:[27,'Escape'],' ':[32,'Space'],ArrowUp:[38,'ArrowUp'],ArrowDown:[40,'ArrowDown'],ArrowLeft:[37,'ArrowLeft'],ArrowRight:[39,'ArrowRight'],Home:[36,'Home'],End:[35,'End'],PageUp:[33,'PageUp'],PageDown:[34,'PageDown']};
      if(map[key])return {keyCode:map[key][0],code:map[key][1]};
      if(key&&key.length===1){const u=key.toUpperCase();
        if(/[A-Z]/.test(u))return {keyCode:u.charCodeAt(0),code:'Key'+u};
        if(/[0-9]/.test(u))return {keyCode:u.charCodeAt(0),code:'Digit'+u};
        return {keyCode:key.charCodeAt(0),code:''};}
      return {keyCode:0,code:key||''};
    }
    function __cmuxKey(target,type,key){
      const meta=__cmuxKeyMeta(key);
      const ev=new KeyboardEvent(type,{key:key,code:meta.code,location:0,repeat:false,isComposing:false,bubbles:true,cancelable:true,composed:true,view:window});
      try{Object.defineProperty(ev,'keyCode',{get(){return meta.keyCode;}});}catch(e){}
      try{Object.defineProperty(ev,'which',{get(){return meta.keyCode;}});}catch(e){}
      return target.dispatchEvent(ev);
    }
    """

    /// JavaScript snippet that sets an input element's value using the native
    /// prototype setter.
    ///
    /// Frameworks like React, Vue, and Angular override the value property on
    /// instances, so a plain `el.value = x` assignment only updates the DOM
    /// without notifying the framework's internal state. Calling the native setter
    /// from the prototype bypasses the override and triggers the framework's
    /// change-detection when followed by an `input` event. Walks the prototype
    /// chain instead of using `instanceof` so it works with cross-realm elements
    /// (iframes) and custom web components. Expects `el` and `newValue` to be in
    /// scope.
    ///
    /// Byte-identical to the former `TerminalController.reactCompatibleSetValue`.
    public static let reactCompatibleSetValue = """
        let nativeSetter = null;
        for (let proto = Object.getPrototypeOf(el); proto; proto = Object.getPrototypeOf(proto)) {
          const desc = Object.getOwnPropertyDescriptor(proto, 'value');
          if (desc && desc.set) { nativeSetter = desc.set; break; }
        }
        if (nativeSetter) {
          nativeSetter.call(el, newValue);
        } else {
          el.value = newValue;
        }
    """

    // MARK: - Selector-action scripts (run inside the v2BrowserSelectorAction loop)

    /// `browser.click` action body. `selectorLiteral` is the already-encoded
    /// JavaScript selector literal (`jsonLiteral(selector)`).
    public func clickScript(selectorLiteral: String) -> String {
        """
        (() => {
          \(Self.inputHelpers)
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          if (el.disabled) return { ok: false, error: 'disabled' };
          el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
          __cmuxClick(el);
          return { ok: true };
        })()
        """
    }

    /// `browser.dblclick` action body.
    public func doubleClickScript(selectorLiteral: String) -> String {
        """
        (() => {
          \(Self.inputHelpers)
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          if (el.disabled) return { ok: false, error: 'disabled' };
          el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
          __cmuxClick(el);
          __cmuxClick(el);
          const c = __cmuxCenter(el);
          __cmuxMouse(el, 'dblclick', c, 0, 2);
          return { ok: true };
        })()
        """
    }

    /// `browser.hover` action body.
    public func hoverScript(selectorLiteral: String) -> String {
        """
        (() => {
          \(Self.inputHelpers)
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
          __cmuxHover(el);
          return { ok: true };
        })()
        """
    }

    /// `browser.focus` action body.
    public func focusElementScript(selectorLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          if (typeof el.focus === 'function') el.focus();
          return { ok: true };
        })()
        """
    }

    /// `browser.type` action body. `textLiteral` is the already-encoded JavaScript
    /// literal for the appended chunk (`jsonLiteral(text)`).
    public func typeScript(selectorLiteral: String, textLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          if (typeof el.focus === 'function') el.focus();
          const chunk = String(\(textLiteral));
          if ('value' in el) {
            const newValue = (el.value || '') + chunk;
            // beforeinput is cancelable; honor a page that rejects the edit (input masks,
            // controlled editors) instead of forcing the value and drifting from app state.
            let proceed = true;
            try { proceed = el.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertText', data: chunk })); } catch (e) {}
            if (!proceed) return { ok: false, error: 'input_rejected' };
            \(Self.reactCompatibleSetValue)
            try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: chunk })); }
            catch (e) { el.dispatchEvent(new Event('input', { bubbles: true })); }
            el.dispatchEvent(new Event('change', { bubbles: true }));
          } else {
            // contenteditable / non-value elements get the same cancelable beforeinput so a rich
            // editor (ProseMirror, Slate, etc.) that manages its own model can reject the edit
            // instead of us silently overwriting textContent and drifting from app state.
            let proceed = true;
            try { proceed = el.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertText', data: chunk })); } catch (e) {}
            if (!proceed) return { ok: false, error: 'input_rejected' };
            el.textContent = (el.textContent || '') + chunk;
            try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: chunk })); } catch (e) {}
          }
          return { ok: true };
        })()
        """
    }

    /// `browser.fill` action body. `textLiteral` is the already-encoded JavaScript
    /// literal for the replacement value (`jsonLiteral(text)`).
    public func fillScript(selectorLiteral: String, textLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          if (typeof el.focus === 'function') el.focus();
          const newValue = String(\(textLiteral));
          if ('value' in el) {
            // beforeinput is cancelable; honor a page that rejects the edit instead of forcing
            // the value and drifting from app state.
            let proceed = true;
            try { proceed = el.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertReplacementText', data: newValue })); } catch (e) {}
            if (!proceed) return { ok: false, error: 'input_rejected' };
            \(Self.reactCompatibleSetValue)
            try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: newValue })); }
            catch (e) { el.dispatchEvent(new Event('input', { bubbles: true })); }
            el.dispatchEvent(new Event('change', { bubbles: true }));
          } else {
            // contenteditable / non-value elements get the same cancelable beforeinput so a rich
            // editor that manages its own model can reject the edit instead of us silently
            // overwriting textContent.
            let proceed = true;
            try { proceed = el.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertReplacementText', data: newValue })); } catch (e) {}
            if (!proceed) return { ok: false, error: 'input_rejected' };
            el.textContent = newValue;
            try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: newValue })); } catch (e) {}
          }
          return { ok: true };
        })()
        """
    }

    /// `browser.check` / `browser.uncheck` action body. `checked` selects the
    /// desired state.
    public func setCheckedScript(selectorLiteral: String, checked: Bool) -> String {
        """
        (() => {
          \(Self.inputHelpers)
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          if (!('checked' in el)) return { ok: false, error: 'not_checkable' };
          if (el.disabled) return { ok: false, error: 'disabled' };
          el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
          if (typeof el.focus === 'function') { try { el.focus({ preventScroll: true }); } catch (e) {} }
          __cmuxSetChecked(el, \(checked ? "true" : "false"));
          if (el.checked !== \(checked ? "true" : "false")) return { ok: false, error: 'not_changed' };
          return { ok: true };
        })()
        """
    }

    /// `browser.select` action body. `valueLiteral` is the already-encoded
    /// JavaScript literal for the option value (`jsonLiteral(value)`).
    public func selectOptionScript(selectorLiteral: String, valueLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          if (!('value' in el)) return { ok: false, error: 'not_select' };
          const newValue = String(\(valueLiteral));
          \(Self.reactCompatibleSetValue)
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { ok: true };
        })()
        """
    }

    /// `browser.scroll_into_view` action body.
    public func scrollIntoViewScript(selectorLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          return { ok: true };
        })()
        """
    }

    /// `browser.highlight` action body. Outlines the matched element for ~1.2s,
    /// then restores its prior `outline`/`outlineOffset` styles.
    public func highlightScript(selectorLiteral: String) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          const prev = el.style.outline;
          const prevOffset = el.style.outlineOffset;
          el.style.outline = '3px solid #ff9f0a';
          el.style.outlineOffset = '2px';
          setTimeout(() => {
            el.style.outline = prev;
            el.style.outlineOffset = prevOffset;
          }, 1200);
          return { ok: true };
        })()
        """
    }

    // MARK: - Press / keydown / keyup scripts (run on the active element)

    /// `browser.press` script. `keyLiteral` is the already-encoded JavaScript
    /// literal for the key (`jsonLiteral(key)`).
    public func pressScript(keyLiteral: String) -> String {
        """
        (() => {
          \(Self.inputHelpers)
          const target = document.activeElement || document.body || document.documentElement;
          if (!target) return { ok: false, error: 'not_found' };
          const k = String(\(keyLiteral));
          const kdNotPrevented = __cmuxKey(target, 'keydown', k);
          // keypress historically fires for character-producing keys, which includes Enter and
          // Space; many pages still bind submit/search to keypress for Enter.
          let kpNotPrevented = true;
          if (k.length === 1 || k === 'Enter') { kpNotPrevented = __cmuxKey(target, 'keypress', k); }
          __cmuxKey(target, 'keyup', k);
          // Synthetic key events do not run WebKit's native "Enter submits the form" default
          // action. Mirror real-user behavior, but only when neither keydown nor keypress was
          // canceled (pages cancel Enter to run their own handling) and the native HTML implicit
          // submission rules would apply: focus is a single-line text-like field AND the form has
          // a submit control or exactly one such field.
          if (k === 'Enter' && kdNotPrevented && kpNotPrevented && target && target.tagName === 'INPUT' && target.form) {
            const submitTypes = ['text','search','email','url','tel','password','number','date','datetime-local','month','week','time'];
            if (submitTypes.indexOf((target.type || 'text').toLowerCase()) !== -1) {
              const hasSubmit = !!target.form.querySelector('input[type=submit],input[type=image],button[type=submit],button:not([type])');
              const textFields = target.form.querySelectorAll('input[type=text],input[type=search],input[type=email],input[type=url],input[type=tel],input[type=password],input[type=number],input[type=date],input[type=datetime-local],input[type=month],input[type=week],input[type=time],input:not([type])');
              if (hasSubmit || textFields.length === 1) {
                try { if (target.form.requestSubmit) { target.form.requestSubmit(); } else { target.form.submit(); } } catch (e) {}
              }
            }
          }
          return { ok: true };
        })()
        """
    }

    /// `browser.keydown` script.
    public func keyDownScript(keyLiteral: String) -> String {
        """
        (() => {
          \(Self.inputHelpers)
          const target = document.activeElement || document.body || document.documentElement;
          if (!target) return { ok: false, error: 'not_found' };
          const k = String(\(keyLiteral));
          __cmuxKey(target, 'keydown', k);
          return { ok: true };
        })()
        """
    }

    /// `browser.keyup` script.
    public func keyUpScript(keyLiteral: String) -> String {
        """
        (() => {
          \(Self.inputHelpers)
          const target = document.activeElement || document.body || document.documentElement;
          if (!target) return { ok: false, error: 'not_found' };
          const k = String(\(keyLiteral));
          __cmuxKey(target, 'keyup', k);
          return { ok: true };
        })()
        """
    }

    // MARK: - Scroll scripts

    /// `browser.scroll` element-scroll body. `dx`/`dy` are the integer deltas.
    public func scrollElementScript(selectorLiteral: String, dx: Int, dy: Int) -> String {
        """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          if (typeof el.scrollBy === 'function') {
            el.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' });
          } else {
            el.scrollLeft += \(dx);
            el.scrollTop += \(dy);
          }
          return { ok: true };
        })()
        """
    }

    /// `browser.scroll` window-scroll body (no selector). `dx`/`dy` are the
    /// integer deltas.
    public func scrollWindowScript(dx: Int, dy: Int) -> String {
        "window.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' }); ({ ok: true })"
    }
}
