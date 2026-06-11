internal import Foundation

/// The browser DOM-automation action bodies (`browser.eval`/`wait`/`click`/…/
/// `screenshot`/`highlight`), with their injected JS byte-identical to the
/// legacy `v2Browser*` originals.
extension ControlCommandCoordinator {
    /// JavaScript snippet that sets an input element's value using the native
    /// prototype setter. Frameworks like React, Vue, and Angular override the
    /// value property on instances, so a plain `el.value = x` assignment only
    /// updates the DOM without notifying the framework's internal state.
    /// Calling the native setter from the prototype bypasses the override and
    /// triggers the framework's change-detection when followed by an `input`
    /// event. Walks the prototype chain instead of using instanceof so it
    /// works with cross-realm elements (iframes) and custom web components.
    /// Expects `el` and `newValue` to be in scope. (Static because it is an
    /// immutable JS source constant shared by several bodies, exactly as on
    /// the legacy controller.)
    private static let reactCompatibleSetValue = """
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

    /// Reusable JS that dispatches framework-correct input events. Synthetic (untrusted) events do
    /// not run native default actions, and many frameworks/libraries listen on the full pointer +
    /// mouse sequence (not just `click`) or need legacy KeyboardEvent fields (keyCode/which/code).
    /// These helpers reproduce a real user gesture so React, Vue, Svelte, Angular, Solid, and
    /// vanilla handlers all fire. Define them once at the top of an injected snippet, then call
    /// `__cmuxClick(el)`, `__cmuxHover(el)`, `__cmuxSetChecked(el, desired)`, and `__cmuxKey(t,type,key)`.
    /// (Static because it is an immutable JS source constant shared by several
    /// bodies, exactly as on the legacy controller.)
    private static let browserInputHelpers = """
    function __cmuxCenter(el){const r=el.getBoundingClientRect();return {x:Math.floor(r.left+Math.min(r.width,r.width/2)),y:Math.floor(r.top+Math.min(r.height,r.height/2))};}
    function __cmuxPointer(el,type,c,buttons){try{el.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,composed:true,view:window,pointerId:1,pointerType:'mouse',isPrimary:true,button:0,buttons:buttons,clientX:c.x,clientY:c.y,screenX:c.x,screenY:c.y}));}catch(e){}}
    function __cmuxMouse(el,type,c,buttons,detail,bubbles){el.dispatchEvent(new MouseEvent(type,{bubbles:(bubbles===false?false:true),cancelable:true,composed:true,view:window,button:0,buttons:buttons,detail:detail||0,clientX:c.x,clientY:c.y,screenX:c.x,screenY:c.y}));}
    function __cmuxClick(el){const c=__cmuxCenter(el);
      __cmuxPointer(el,'pointerover',c,0);__cmuxMouse(el,'mouseover',c,0);
      __cmuxPointer(el,'pointerenter',c,0);__cmuxMouse(el,'mouseenter',c,0,0,false);
      __cmuxPointer(el,'pointermove',c,0);__cmuxMouse(el,'mousemove',c,0);
      __cmuxPointer(el,'pointerdown',c,1);__cmuxMouse(el,'mousedown',c,1,1);
      if(typeof el.focus==='function'){try{el.focus({preventScroll:true});}catch(e){try{el.focus();}catch(e2){}}}
      __cmuxPointer(el,'pointerup',c,0);__cmuxMouse(el,'mouseup',c,0,1);
      if(typeof el.click==='function'){el.click();}else{__cmuxMouse(el,'click',c,0,1);}
    }
    function __cmuxHover(el){const c=__cmuxCenter(el);
      __cmuxPointer(el,'pointerover',c,0);__cmuxMouse(el,'mouseover',c,0);
      __cmuxPointer(el,'pointerenter',c,0);__cmuxMouse(el,'mouseenter',c,0,0,false);
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

    /// `browser.eval` — evaluate a script in the page (frame-scoped).
    func browserEval(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let script = string(params, "script") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return withBrowserPanel(params) { workspaceID, surfaceID in
            switch browserRunScript(surfaceID: surfaceID, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                payload["value"] = browserPayloadValue(value)
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.wait` — wait for a selector/url/text/load-state/function
    /// condition.
    func browserWait(_ params: [String: JSONValue]) -> ControlCallResult {
        let timeoutMs = max(1, int(params, "timeout_ms") ?? 5_000)
        let selectorRaw = browserSelectorParam(params)

        let conditionScriptBase: String = {
            if let urlContains = string(params, "url_contains") {
                let literal = browserJSONLiteral(urlContains)
                return "String(location.href || '').includes(\(literal))"
            }
            if let textContains = string(params, "text_contains") {
                let literal = browserJSONLiteral(textContains)
                return "(document.body && String(document.body.innerText || '').includes(\(literal)))"
            }
            if let loadState = string(params, "load_state") {
                let normalizedLoadState = loadState.lowercased()
                if normalizedLoadState == "interactive" {
                    return """
                    (() => {
                      const __state = String(document.readyState || '').toLowerCase();
                      return __state === 'interactive' || __state === 'complete';
                    })()
                    """
                }
                let literal = browserJSONLiteral(normalizedLoadState)
                return "String(document.readyState || '').toLowerCase() === \(literal)"
            }
            if let fn = string(params, "function") {
                return "(() => { return !!(\(fn)); })()"
            }
            return "document.readyState === 'complete'"
        }()

        let resolution = browserContext?.controlBrowserResolveWaitPanel(
            routing: routingSelectors(params),
            surfaceID: uuid(params, "surface_id")
        ) ?? .tabManagerUnavailable
        guard case .resolved(let workspaceID, let surfaceID) = resolution else {
            return browserPanelResolutionError(resolution)
        }

        let conditionScript: String
        if let selectorRaw {
            guard let selector = browserContext?.controlBrowserAutomationState
                .resolveSelector(selectorRaw, surfaceID: surfaceID) else {
                return .err(
                    code: "not_found",
                    message: "Element reference not found",
                    data: .object(["selector": .string(selectorRaw)])
                )
            }
            let literal = browserJSONLiteral(selector)
            conditionScript = "document.querySelector(\(literal)) !== null"
        } else {
            conditionScript = conditionScriptBase
        }

        if browserWaitForCondition(
            surfaceID: surfaceID,
            conditionScript: conditionScript,
            timeoutMs: timeoutMs
        ) {
            var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
            payload["waited"] = .bool(true)
            return .ok(.object(payload))
        }
        return .err(
            code: "timeout",
            message: "Condition not met before timeout",
            data: .object(["timeout_ms": .int(Int64(timeoutMs))])
        )
    }

    /// `browser.click` — full pointer/mouse click sequence on an element.
    func browserClick(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "click") { selectorLiteral in
            """
            (() => {
              \(Self.browserInputHelpers)
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (el.disabled) return { ok: false, error: 'disabled' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              __cmuxClick(el);
              return { ok: true };
            })()
            """
        }
    }

    /// `browser.dblclick` — double-click an element.
    func browserDblClick(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "dblclick") { selectorLiteral in
            """
            (() => {
              \(Self.browserInputHelpers)
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
    }

    /// `browser.hover` — hover an element.
    func browserHover(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "hover") { selectorLiteral in
            """
            (() => {
              \(Self.browserInputHelpers)
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              __cmuxHover(el);
              return { ok: true };
            })()
            """
        }
    }

    /// `browser.focus` — focus an element.
    func browserFocusElement(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "focus") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              return { ok: true };
            })()
            """
        }
    }

    /// `browser.type` — append text to an element's value.
    func browserType(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let text = string(params, "text") else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        return browserSelectorAction(params, actionName: "type") { selectorLiteral in
            let textLiteral = browserJSONLiteral(text)
            return """
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
                el.textContent = (el.textContent || '') + chunk;
                try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: chunk })); } catch (e) {}
              }
              return { ok: true };
            })()
            """
        }
    }

    /// `browser.fill` — replace an element's value (empty string allowed, so
    /// callers can clear inputs).
    func browserFill(_ params: [String: JSONValue]) -> ControlCallResult {
        // `fill` must allow empty strings so callers can clear existing input values.
        guard let text = rawString(params, "text") ?? rawString(params, "value") else {
            return .err(code: "invalid_params", message: "Missing text/value", data: nil)
        }
        return browserSelectorAction(params, actionName: "fill") { selectorLiteral in
            let textLiteral = browserJSONLiteral(text)
            return """
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
                el.textContent = newValue;
                try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: newValue })); } catch (e) {}
              }
              return { ok: true };
            })()
            """
        }
    }

    /// `browser.press` — full keydown/keypress/keyup on the active element,
    /// with the native implicit form-submission mirror for Enter.
    func browserPress(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let key = string(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        return withBrowserPanel(params) { workspaceID, surfaceID in
            let keyLiteral = browserJSONLiteral(key)
            let script = """
            (() => {
              \(Self.browserInputHelpers)
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
            switch browserRunScript(surfaceID: surfaceID, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                browserAppendPostSnapshot(params, surfaceID: surfaceID, payload: &payload)
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.keydown` — dispatch a keydown on the active element.
    func browserKeyDown(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let key = string(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return withBrowserPanel(params) { workspaceID, surfaceID in
            let keyLiteral = browserJSONLiteral(key)
            let script = """
            (() => {
              \(Self.browserInputHelpers)
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              __cmuxKey(target, 'keydown', k);
              return { ok: true };
            })()
            """
            switch browserRunScript(surfaceID: surfaceID, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                browserAppendPostSnapshot(params, surfaceID: surfaceID, payload: &payload)
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.keyup` — dispatch a keyup on the active element.
    func browserKeyUp(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let key = string(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return withBrowserPanel(params) { workspaceID, surfaceID in
            let keyLiteral = browserJSONLiteral(key)
            let script = """
            (() => {
              \(Self.browserInputHelpers)
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              __cmuxKey(target, 'keyup', k);
              return { ok: true };
            })()
            """
            switch browserRunScript(surfaceID: surfaceID, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                browserAppendPostSnapshot(params, surfaceID: surfaceID, payload: &payload)
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.check` / `browser.uncheck` — drive a checkbox/radio to the
    /// target state with framework-correct events.
    func browserCheck(_ params: [String: JSONValue], checked: Bool) -> ControlCallResult {
        browserSelectorAction(params, actionName: checked ? "check" : "uncheck") { selectorLiteral in
            """
            (() => {
              \(Self.browserInputHelpers)
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
    }

    /// `browser.select` — set a select/option value.
    func browserSelect(_ params: [String: JSONValue]) -> ControlCallResult {
        let selectedValue = string(params, "value") ?? string(params, "text")
        guard let selectedValue else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }
        return browserSelectorAction(params, actionName: "select") { selectorLiteral in
            let valueLiteral = browserJSONLiteral(selectedValue)
            return """
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
    }

    /// `browser.scroll` — scroll the window or an element by a delta.
    func browserScroll(_ params: [String: JSONValue]) -> ControlCallResult {
        let dx = int(params, "dx") ?? 0
        let dy = int(params, "dy") ?? 0
        let selectorRaw = browserSelectorParam(params)

        return withBrowserPanel(params) { workspaceID, surfaceID in
            let selector = selectorRaw.flatMap {
                browserContext?.controlBrowserAutomationState.resolveSelector($0, surfaceID: surfaceID)
            }
            if selectorRaw != nil && selector == nil {
                return .err(
                    code: "not_found",
                    message: "Element reference not found",
                    data: .object(["selector": .string(selectorRaw ?? "")])
                )
            }

            let script: String
            if let selector {
                let selectorLiteral = browserJSONLiteral(selector)
                script = """
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
            } else {
                script = "window.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' }); ({ ok: true })"
            }

            switch browserRunScript(surfaceID: surfaceID, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = browserScriptObject(value),
                   browserExactBool(dict["ok"]) == false,
                   browserStringValue(dict["error"]) == "not_found" {
                    if let selector {
                        return browserElementNotFoundResult(
                            actionName: "scroll",
                            selector: selector,
                            attempts: 1,
                            surfaceID: surfaceID
                        )
                    }
                    return .err(
                        code: "not_found",
                        message: "Element not found",
                        data: .object(["selector": .string(selector ?? "")])
                    )
                }
                var payload = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
                browserAppendPostSnapshot(params, surfaceID: surfaceID, payload: &payload)
                return .ok(.object(payload))
            }
        }
    }

    /// `browser.scroll_into_view` — center an element in the viewport.
    func browserScrollIntoView(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "scroll_into_view") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
              return { ok: true };
            })()
            """
        }
    }

    /// `browser.screenshot` — capture the visible viewport as PNG, returning
    /// base64 plus a best-effort temp-file path.
    func browserScreenshot(_ params: [String: JSONValue]) -> ControlCallResult {
        withBrowserPanel(params) { workspaceID, surfaceID in
            let capture = browserContext?.controlBrowserCaptureScreenshot(surfaceID: surfaceID) ?? .captureFailed
            let imageData: Data
            switch capture {
            case .timedOut:
                return .err(code: "timeout", message: "Timed out waiting for snapshot", data: nil)
            case .captureFailed:
                return .err(code: "internal_error", message: "Failed to capture snapshot", data: nil)
            case .png(let data):
                imageData = data
            }

            var result = browserIdentityPayload(workspaceID: workspaceID, surfaceID: surfaceID)
            result["png_base64"] = .string(imageData.base64EncodedString())

            // Best effort: keep screenshot data available even when temp-file writes fail.
            let screenshotsDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-browser-screenshots", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)) != nil {
                browserBestEffortPruneTemporaryFiles(in: screenshotsDirectory)
                let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
                let shortSurfaceId = String(surfaceID.uuidString.prefix(8))
                let shortRandomId = String(UUID().uuidString.prefix(8))
                let filename = "surface-\(shortSurfaceId)-\(timestampMs)-\(shortRandomId).png"
                let imageURL = screenshotsDirectory.appendingPathComponent(filename, isDirectory: false)
                if (try? imageData.write(to: imageURL, options: .atomic)) != nil {
                    result["path"] = .string(imageURL.path)
                    result["url"] = .string(imageURL.absoluteString)
                }
            }

            return .ok(.object(result))
        }
    }

    /// Trims the screenshot temp directory (was
    /// `bestEffortPruneTemporaryFiles`, whose only caller was the screenshot
    /// body): keeps the newest `maxCount` regular files and drops anything
    /// older than `maxAge`.
    private func browserBestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    /// `browser.highlight` — flash an outline around an element.
    func browserHighlight(_ params: [String: JSONValue]) -> ControlCallResult {
        browserSelectorAction(params, actionName: "highlight") { selectorLiteral in
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
    }
}
