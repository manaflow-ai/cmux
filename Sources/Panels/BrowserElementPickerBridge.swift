import Foundation

enum BrowserElementPickerBridge {
    static let messageHandlerName = "cmuxElementPicker"

    static func setActiveScript(_ isActive: Bool) -> String {
        let value = isActive ? "true" : "false"
        return """
        (() => {
          window.__cmuxElementPickerPendingActive = \(value);
          const picker = window.__cmuxElementPicker;
          if (picker && typeof picker.setActive === 'function') {
            return picker.setActive(\(value));
          }
          return false;
        })()
        """
    }

    static let scriptSource = """
    (() => {
      if (window.__cmuxElementPickerInstalled) {
        return true;
      }

      const handlerName = '\(messageHandlerName)';
      const getHandler = () => {
        try {
          return window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handlerName];
        } catch (_) {
          return null;
        }
      };

      const state = window.__cmuxElementPickerState || { active: false, overlay: null };
      Object.defineProperty(window, '__cmuxElementPickerState', {
        value: state,
        writable: false,
        configurable: false,
        enumerable: false
      });
      Object.defineProperty(window, '__cmuxElementPickerInstalled', {
        value: true,
        writable: false,
        configurable: false,
        enumerable: false
      });

      const cssEscape = (value) => {
        const string = String(value || '');
        if (window.CSS && typeof window.CSS.escape === 'function') {
          return window.CSS.escape(string);
        }
        return string.replace(/[^a-zA-Z0-9_-]/g, (ch) => '\\\\' + ch);
      };

      const attributeSelectorValue = (value) => Array.from(String(value || ''), (ch) => {
        if (ch === String.fromCharCode(92)) return String.fromCharCode(92, 92);
        if (ch === '"') return String.fromCharCode(92, 34);
        return ch;
      }).join('');

      const sanitizedText = (value, limit) => {
        return String(value || '')
          .replace(/[\\u0000-\\u001f\\u007f-\\u009f\\u200b-\\u200f\\u202a-\\u202e\\u2066-\\u2069\\ufeff]/g, '')
          .slice(0, limit)
          .trim();
      };

      const elementFromEvent = (event) => {
        const path = event && typeof event.composedPath === 'function' ? event.composedPath() : [];
        for (const item of path) {
          if (item && item.nodeType === Node.ELEMENT_NODE) return item;
        }
        return event && event.target && event.target.nodeType === Node.ELEMENT_NODE ? event.target : null;
      };

      const ensureOverlay = () => {
        if (state.overlay && state.overlay.isConnected) return state.overlay;
        const overlay = document.createElement('div');
        overlay.setAttribute('aria-hidden', 'true');
        overlay.setAttribute('role', 'presentation');
        overlay.style.cssText = [
          'position:fixed',
          'pointer-events:none',
          'z-index:2147483647',
          'border:2px solid #0a84ff',
          'background:rgba(10,132,255,0.14)',
          'display:none',
          'border-radius:3px',
          'box-sizing:border-box'
        ].join(';');
        if (!window.matchMedia || !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
          overlay.style.transition = 'top 40ms linear,left 40ms linear,width 40ms linear,height 40ms linear';
        }
        (document.body || document.documentElement).appendChild(overlay);
        state.overlay = overlay;
        return overlay;
      };

      const hideOverlay = () => {
        if (state.overlay) state.overlay.style.display = 'none';
      };

      const showOverlay = (element, picked) => {
        if (!element || typeof element.getBoundingClientRect !== 'function') {
          hideOverlay();
          return;
        }
        const rect = element.getBoundingClientRect();
        const overlay = ensureOverlay();
        overlay.style.display = 'block';
        overlay.style.borderColor = picked ? '#30d158' : '#0a84ff';
        overlay.style.background = picked ? 'rgba(48,209,88,0.16)' : 'rgba(10,132,255,0.14)';
        overlay.style.top = rect.top + 'px';
        overlay.style.left = rect.left + 'px';
        overlay.style.width = Math.max(0, rect.width) + 'px';
        overlay.style.height = Math.max(0, rect.height) + 'px';
      };

      const nthOfType = (element) => {
        let index = 1;
        let sibling = element.previousElementSibling;
        while (sibling) {
          if (sibling.localName === element.localName) index += 1;
          sibling = sibling.previousElementSibling;
        }
        return index;
      };

      const simpleSelector = (element, root) => {
        const tag = (element.localName || 'element').toLowerCase();
        if (element.id) {
          return tag + '#' + cssEscape(element.id);
        }

        for (const attributeName of ['data-testid', 'data-test', 'data-cy']) {
          const testId = element.getAttribute(attributeName);
          if (testId) {
            return tag + '[' + attributeName + '="' + attributeSelectorValue(testId) + '"]';
          }
        }

        const name = element.getAttribute('name');
        if (name) {
          return tag + '[name="' + attributeSelectorValue(name) + '"]';
        }

        const parent = element.parentElement || (root && root.host) || null;
        if (!parent) return tag;
        const sameTagSiblings = Array.prototype.filter.call(parent.children || [], (child) => child.localName === element.localName);
        return sameTagSiblings.length > 1 ? tag + ':nth-of-type(' + nthOfType(element) + ')' : tag;
      };

      const selectorPath = (element, root) => {
        const parts = [];
        let current = element;
        while (current && current.nodeType === Node.ELEMENT_NODE && current !== root) {
          parts.unshift(simpleSelector(current, root));
          if (current.id) break;
          current = current.parentElement;
        }
        return parts.join(' > ');
      };

      const xpathForElement = (element) => {
        const parts = [];
        let current = element;
        while (current && current.nodeType === Node.ELEMENT_NODE) {
          const tag = (current.localName || 'element').toLowerCase();
          if (current === document.documentElement) {
            parts.unshift('html');
            break;
          }
          const index = nthOfType(current);
          const parent = current.parentElement;
          const sameTagCount = parent ? Array.prototype.filter.call(parent.children || [], (child) => child.localName === current.localName).length : 1;
          parts.unshift(sameTagCount > 1 ? tag + '[' + index + ']' : tag);
          current = parent;
        }
        return '/' + parts.join('/');
      };

      const selectorDescription = (element) => {
        const shadowPath = [];
        let current = element;
        let root = current.getRootNode ? current.getRootNode() : document;
        while (root && root.toString && String(root) === '[object ShadowRoot]') {
          shadowPath.unshift(selectorPath(current, root));
          current = root.host;
          root = current && current.getRootNode ? current.getRootNode() : document;
        }
        const outer = selectorPath(current, document);
        if (shadowPath.length > 0) {
          const path = [outer].concat(shadowPath);
          return { selector: path.join(' >> shadow >> '), selector_kind: 'shadow', shadow_path: path, xpath: null };
        }
        return { selector: selectorPath(element, document), selector_kind: 'css', shadow_path: [], xpath: xpathForElement(element) };
      };

      const whitelistedAttributes = (element) => {
        const keys = ['id', 'class', 'name', 'type', 'href', 'role', 'aria-label', 'title', 'alt', 'data-testid', 'data-test', 'data-cy'];
        const out = {};
        for (const key of keys) {
          const value = element.getAttribute && element.getAttribute(key);
          if (value) out[key] = sanitizedText(value, 300);
        }
        return out;
      };

      const payloadFor = (element, event, pickedViaActiveMode) => {
        const selector = selectorDescription(element);
        const rect = element.getBoundingClientRect();
        const attributes = whitelistedAttributes(element);
        const text = sanitizedText(element.innerText || element.textContent || element.getAttribute('aria-label') || element.getAttribute('title') || '', 500);
        return {
          selector: selector.selector,
          selector_kind: selector.selector_kind,
          shadow_path: selector.shadow_path,
          xpath: selector.xpath,
          text: text,
          tag: (element.localName || 'element').toLowerCase(),
          role: element.getAttribute('role') || '',
          label: element.getAttribute('aria-label') || element.getAttribute('title') || element.getAttribute('alt') || '',
          attributes: attributes,
          url: String(document.URL || ''),
          title: String(document.title || ''),
          frame_url: String(window.location && window.location.href || ''),
          rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
          activation: pickedViaActiveMode ? 'armed' : 'option',
          pointer: { x: event.clientX, y: event.clientY },
          timestamp_ms: Date.now()
        };
      };

      const setActive = (active) => {
        state.active = !!active;
        if (!state.active) {
          hideOverlay();
        }
        return state.active;
      };

      Object.defineProperty(window, '__cmuxElementPicker', {
        value: {
          setActive,
          isActive: () => !!state.active
        },
        writable: false,
        configurable: false,
        enumerable: false
      });

      document.addEventListener('mousemove', (event) => {
        if (!state.active && !event.altKey) {
          hideOverlay();
          return;
        }
        showOverlay(elementFromEvent(event), false);
      }, true);

      document.addEventListener('click', (event) => {
        const pickedViaActiveMode = !!state.active;
        if (!pickedViaActiveMode && !event.altKey) return;
        const element = elementFromEvent(event);
        if (!element) return;
        event.preventDefault();
        event.stopPropagation();
        showOverlay(element, true);
        setActive(false);
        try {
          const handler = getHandler();
          if (handler) handler.postMessage(payloadFor(element, event, pickedViaActiveMode));
        } catch (_) {}
      }, true);

      window.addEventListener('blur', hideOverlay, true);
      document.addEventListener('visibilitychange', () => {
        if (document.hidden) hideOverlay();
      }, true);

      if (window.__cmuxElementPickerPendingActive === true) {
        setActive(true);
      }

      return true;
    })()
    """
}
