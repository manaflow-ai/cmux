/// JavaScript generation for canonical browser keyboard events.
extension BrowserControlService {
    /// Builds the browser script for one keyboard automation action.
    ///
    /// - Parameters:
    ///   - action: Whether to press, hold down, or release the key.
    ///   - event: Canonical DOM fields resolved by ``BrowserKeyboardEvent``.
    /// - Returns: A self-invoking JavaScript expression.
    public func keyboardScript(action: BrowserKeyboardAction, event: BrowserKeyboardEvent) -> String {
        let actionBody: String
        switch action {
        case .press:
            actionBody = """
              const __cmuxKeyDownNotPrevented = __cmuxDispatchKey(target, 'keydown');
              let __cmuxKeyPressNotPrevented = true;
              if (__cmuxKeyValue.length === 1 || __cmuxKeyValue === 'Enter') {
                __cmuxKeyPressNotPrevented = __cmuxDispatchKey(target, 'keypress');
              }
              const __cmuxKeyUpNotPrevented = __cmuxDispatchKey(target, 'keyup');

              // Synthetic keyboard events do not invoke WebKit's activation behavior. A DOM click
              // reproduces keyboard activation (detail === 0) for controls that natively activate
              // on Space, while honoring handlers that canceled any part of the key sequence.
              if (__cmuxKeyValue === ' ' && __cmuxKeyDownNotPrevented && __cmuxKeyPressNotPrevented && __cmuxKeyUpNotPrevented && __cmuxSpaceActivates(target)) {
                try { target.click(); } catch (_) {}
              }

              // Synthetic Enter events also do not run WebKit's implicit form-submission default.
              // Preserve the existing behavior for a focused single-line text-like form field.
              if (__cmuxKeyValue === 'Enter' && __cmuxKeyDownNotPrevented && __cmuxKeyPressNotPrevented && target && target.tagName === 'INPUT' && target.form) {
                const submitTypes = ['text','search','email','url','tel','password','number','date','datetime-local','month','week','time'];
                if (submitTypes.indexOf((target.type || 'text').toLowerCase()) !== -1) {
                  const hasSubmit = !!target.form.querySelector('input[type=submit],input[type=image],button[type=submit],button:not([type])');
                  const textFields = target.form.querySelectorAll('input[type=text],input[type=search],input[type=email],input[type=url],input[type=tel],input[type=password],input[type=number],input[type=date],input[type=datetime-local],input[type=month],input[type=week],input[type=time],input:not([type])');
                  if (hasSubmit || textFields.length === 1) {
                    try { if (target.form.requestSubmit) { target.form.requestSubmit(); } else { target.form.submit(); } } catch (_) {}
                  }
                }
              }
            """
        case .keyDown:
            actionBody = "__cmuxDispatchKey(target, 'keydown');"
        case .keyUp:
            actionBody = "__cmuxDispatchKey(target, 'keyup');"
        }

        let keyLiteral = jsonLiteral(event.key)
        let codeLiteral = jsonLiteral(event.code)
        return """
        (() => {
          const __cmuxKeyValue = \(keyLiteral);
          const __cmuxCodeValue = \(codeLiteral);
          const __cmuxLegacyKeyCode = \(event.legacyKeyCode);
          const __cmuxLocation = \(event.location);
          const __cmuxDispatchKey = (target, type) => {
            const keyboardEvent = new KeyboardEvent(type, {
              key: __cmuxKeyValue,
              code: __cmuxCodeValue,
              location: __cmuxLocation,
              repeat: false,
              isComposing: false,
              bubbles: true,
              cancelable: true,
              composed: true,
              view: window
            });
            try { Object.defineProperty(keyboardEvent, 'keyCode', { get() { return __cmuxLegacyKeyCode; } }); } catch (_) {}
            try { Object.defineProperty(keyboardEvent, 'which', { get() { return __cmuxLegacyKeyCode; } }); } catch (_) {}
            return target.dispatchEvent(keyboardEvent);
          };
          const __cmuxSpaceActivates = (target) => {
            if (!target || typeof target.matches !== 'function') return false;
            return target.matches('button,input[type=button],input[type=submit],input[type=reset],input[type=checkbox],input[type=radio]');
          };
          const target = document.activeElement || document.body || document.documentElement;
          if (!target) return { ok: false, error: 'not_found' };
        \(actionBody)
          return { ok: true };
        })()
        """
    }
}
