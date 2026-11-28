import Foundation

/// Keeps element fullscreen inside the pane.
///
/// WebKit's native element fullscreen moves content into its own window that
/// takes the whole display. cmux disables it (`isElementFullscreenEnabled =
/// false`) and installs this shim instead: `requestFullscreen` pins the
/// element over the page's viewport with CSS, the Fullscreen API getters and
/// events behave as usual (entering needs user activation), Escape exits, and the page reports state changes
/// through the `cmuxPaneFullscreen` message handler so the chrome can hide.
nonisolated enum PaneFullscreenScript {
    static let messageHandlerName = "cmuxPaneFullscreen"

    static let exitScript = "window.__cmuxPaneFullscreen && window.__cmuxPaneFullscreen.exit();"

    static let source = #"""
    (() => {
      if (window.__cmuxPaneFullscreen) return;
      const ATTR = 'data-cmux-pane-fullscreen';
      const ROOT_ATTR = 'data-cmux-pane-fullscreen-root';
      const STYLE_ID = '__cmux_pane_fullscreen_style';
      let current = null;

      const post = (on) => {
        if (window.top !== window) return;
        try { window.webkit.messageHandlers.cmuxPaneFullscreen.postMessage(on); } catch (_) {}
      };
      const ensureStyle = () => {
        if (document.getElementById(STYLE_ID)) return;
        const style = document.createElement('style');
        style.id = STYLE_ID;
        style.textContent =
          `[${ATTR}]{position:fixed!important;inset:0!important;width:100vw!important;` +
          `height:100vh!important;max-width:none!important;max-height:none!important;` +
          `margin:0!important;padding:0!important;border:0!important;transform:none!important;` +
          `z-index:2147483647!important;background:#000!important;object-fit:contain!important}` +
          `html[${ROOT_ATTR}],html[${ROOT_ATTR}] body{overflow:hidden!important}`;
        (document.head || document.documentElement).appendChild(style);
      };
      const fire = (element) => {
        for (const name of ['fullscreenchange', 'webkitfullscreenchange']) {
          element.dispatchEvent(new Event(name, { bubbles: true }));
          if (!element.isConnected || element.ownerDocument !== document) {
            document.dispatchEvent(new Event(name, { bubbles: true }));
          }
        }
      };
      const leave = (notify) => {
        const element = current;
        if (!element) return;
        element.removeAttribute(ATTR);
        document.documentElement.removeAttribute(ROOT_ATTR);
        current = null;
        if (notify) { post(false); fire(element); }
      };
      function enter() {
        const element = this;
        if (current === element) return Promise.resolve();
        // Like the real Fullscreen API: only in answer to the user.
        if (navigator.userActivation && !navigator.userActivation.isActive) {
          return Promise.reject(new TypeError('Fullscreen request denied: no user activation'));
        }
        if (current) leave(true);
        ensureStyle();
        current = element;
        element.setAttribute(ATTR, '');
        document.documentElement.setAttribute(ROOT_ATTR, '');
        post(true);
        fire(element);
        return Promise.resolve();
      }
      const exit = () => { leave(true); return Promise.resolve(); };

      for (const name of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
        Element.prototype[name] = enter;
      }
      if (window.HTMLVideoElement) {
        HTMLVideoElement.prototype.webkitEnterFullscreen = enter;
        HTMLVideoElement.prototype.webkitEnterFullScreen = enter;
      }
      for (const name of ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen']) {
        Document.prototype[name] = exit;
      }
      const getter = (name, get) => {
        try { Object.defineProperty(Document.prototype, name, { configurable: true, get }); } catch (_) {}
      };
      for (const name of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement']) {
        getter(name, () => current);
      }
      for (const name of ['fullscreenEnabled', 'webkitFullscreenEnabled']) getter(name, () => true);
      for (const name of ['fullscreen', 'webkitIsFullScreen']) getter(name, () => current !== null);

      document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape' && current) {
          event.stopImmediatePropagation();
          event.preventDefault();
          exit();
        }
      }, true);
      window.addEventListener('pagehide', () => leave(true));
      window.__cmuxPaneFullscreen = { exit };
    })();
    """#
}

/// Find-in-page helpers. WebKit's `find` highlights but does not count.
nonisolated enum FindScripts {
    /// Counts case-insensitive occurrences of `needle` in visible body text.
    /// Arguments: `needle` (String), `caseSensitive` (Bool).
    static let countBody = #"""
    if (!needle || !document.body) return 0;
    const text = caseSensitive ? document.body.innerText : document.body.innerText.toLowerCase();
    const target = caseSensitive ? needle : needle.toLowerCase();
    let count = 0, index = text.indexOf(target);
    while (index !== -1 && count < 10000) { count += 1; index = text.indexOf(target, index + target.length); }
    return count;
    """#

    static let clearSelection = "window.getSelection() && window.getSelection().removeAllRanges();"
}

/// Finds the best favicon URL of the current document.
nonisolated enum FaviconScript {
    static let source = #"""
    (() => {
      const links = [...document.querySelectorAll('link[rel]')].filter((link) => {
        const rel = link.rel.toLowerCase().split(/\s+/);
        return rel.includes('icon') || rel.includes('apple-touch-icon');
      });
      const size = (link) => {
        const value = (link.getAttribute('sizes') || '').toLowerCase();
        if (value === 'any') return 1024;
        const match = value.match(/(\d+)x(\d+)/);
        return match ? parseInt(match[1], 10) : (link.rel.toLowerCase().includes('apple') ? 180 : 16);
      };
      const scored = links
        .map((link) => ({ href: link.href, score: Math.abs(size(link) - 64) }))
        .filter((entry) => entry.href && !entry.href.startsWith('data:image/svg'));
      scored.sort((a, b) => a.score - b.score);
      if (scored.length) return scored[0].href;
      return location.protocol.startsWith('http') ? location.origin + '/favicon.ico' : null;
    })();
    """#
}
