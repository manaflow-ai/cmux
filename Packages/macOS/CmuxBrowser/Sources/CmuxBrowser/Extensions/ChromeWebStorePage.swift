// Portions adapted from Search (https://github.com/driceroland/Search,
// Sources/Search/StoreRelay.swift and ExtensionsUI.swift at
// 491f3214063212fac176a7ad95467f0821040451),
// Copyright (c) 2026 Office Commun, MIT License. See THIRD_PARTY_LICENSES.md.

public import Foundation

/// Makes the Chrome Web Store usable from cmux.
///
/// The store detects a non-Chrome browser and shows a "Switch to Chrome"
/// banner, a floating "Switch to Chrome?" card, and a disabled
/// "Add to Chrome" button. The page script hides the banner and card and
/// places an enabled "Add to cmux" button beside the disabled one.
///
/// Trust boundary: the script runs in an isolated content world, so page
/// JavaScript can neither call its message handler nor read its state. The
/// script only *asks* to install; the native side reads the extension id from
/// the web view's own URL (never from the message), requires the message to
/// come from the main frame of a store page, and shows a confirmation dialog
/// before anything is downloaded.
public enum ChromeWebStorePage {
    /// Script message handler name, registered in the isolated world only.
    public static let messageHandlerName = "cmuxChromeWebStore"

    /// Name of the isolated `WKContentWorld` the script runs in.
    public static let contentWorldName = "cmux-chrome-web-store"

    /// Where "Chrome Web Store" links in cmux go.
    public static let storeHomeURL = URL(string: "https://chromewebstore.google.com/category/extensions")!

    /// Whether `url` is a Chrome Web Store page.
    public static func isStorePage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        let host = url.host?.lowercased() ?? ""
        return host == "chromewebstore.google.com"
            || (host == "chrome.google.com" && url.path.hasPrefix("/webstore"))
    }

    /// The extension id of a store detail page, taken from the URL path only.
    ///
    /// The id is the segment right after `detail`, or the one after that when
    /// a slug comes first (`/detail/<slug>/<id>`). The page script uses the
    /// same rule, so the button it labels and the extension the app installs
    /// cannot disagree.
    public static func extensionID(onStorePage url: URL) -> String? {
        guard isStorePage(url) else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let detail = components.firstIndex(of: "detail") else { return nil }
        for offset in 1...2 where components.indices.contains(detail + offset) {
            if ChromeExtensionPackage.isExtensionID(components[detail + offset]) {
                return components[detail + offset]
            }
        }
        return nil
    }

    /// Localized labels for the injected button.
    public struct Labels: Encodable, Sendable {
        public var add: String
        public var adding: String
        public var added: String

        public init(add: String, adding: String, added: String) {
            self.add = add
            self.adding = adding
            self.added = added
        }
    }

    /// Install state pushed into the page so the button can say
    /// "Adding..." or "Added".
    public struct State: Encodable, Equatable, Sendable {
        public var installed: [String]
        public var busy: String?

        public init(installed: [String], busy: String?) {
            self.installed = installed
            self.busy = busy
        }
    }

    /// JavaScript that updates the page's button state.
    public static func stateUpdateScript(_ state: State) -> String {
        let json = (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return "window.__cmuxChromeWebStore && window.__cmuxChromeWebStore.state(\(json));"
    }

    /// The user script. Inject at document end, main frame only, in the
    /// isolated world named ``contentWorldName``.
    ///
    /// The store's markup is generated and its class names change between
    /// releases, so the script keys off stable semantics: the store's own
    /// install button is the disabled button whose text names Chrome, the
    /// banner is the small block around the enabled button whose
    /// aria-label names Chrome, and the floating card is the dialog carrying
    /// the Chrome product logo.
    public static func userScriptSource(labels: Labels) -> String {
        let labelsJSON = (try? JSONEncoder().encode(labels)).flatMap { String(data: $0, encoding: .utf8) }
        return """
        (function () {
          if (location.hostname !== 'chromewebstore.google.com' || window.__cmuxChromeWebStore) return;
          var labels = \(labelsJSON ?? #"{"add":"Add to cmux","adding":"Adding…","added":"Added to cmux"}"#);
          var state = { installed: [], busy: null };
          var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageHandlerName);
          if (!handler) return;

          function pageID() {
            // Same rule as the app: the segment after "detail", else the next.
            var parts = location.pathname.split('/').filter(function (p) { return p.length; });
            var d = parts.indexOf('detail');
            if (d < 0) return null;
            for (var i = 1; i <= 2; i++) {
              if (/^[a-p]{32}$/.test(parts[d + i] || '')) return parts[d + i];
            }
            return null;
          }

          function storeButton() {
            var buttons = document.querySelectorAll('button[disabled]');
            for (var i = 0; i < buttons.length; i++) {
              var b = buttons[i];
              if (!b.dataset.cmux && /chrome/i.test(b.textContent || '')) return b;
            }
            return null;
          }

          // Walk up from the banner's button while the block stays small and
          // holds no install button, so the extension header is never hidden.
          function bannerOf(button) {
            var box = null, up = button.parentElement;
            while (up && up !== document.body) {
              if (up.querySelector('button[disabled], button[data-cmux]')) break;
              if ((up.innerText || '').length > 160) break;
              box = up;
              up = up.parentElement;
            }
            return box;
          }

          function hidePromotions() {
            var cards = document.querySelectorAll('[role="dialog"]');
            for (var c = 0; c < cards.length; c++) {
              if (!cards[c].dataset.cmux && cards[c].querySelector('img[src*="productlogos/chrome"]')) {
                cards[c].style.display = 'none';
                cards[c].dataset.cmux = 'promo';
              }
            }
            var buttons = document.querySelectorAll('button:not([disabled])');
            for (var i = 0; i < buttons.length; i++) {
              var b = buttons[i];
              if (b.dataset.cmux || !/chrome/i.test(b.getAttribute('aria-label') || '')) continue;
              var box = bannerOf(b);
              if (box && !box.dataset.cmux) {
                box.style.display = 'none';
                box.dataset.cmux = 'banner';
              }
            }
          }

          // Replace only the text so the button keeps the store's styling.
          function setLabel(button, text) {
            var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
            var node, last = null;
            while ((node = walker.nextNode())) { if (node.nodeValue.trim()) last = node; }
            if (last) last.nodeValue = text; else button.textContent = text;
          }

          function render(button) {
            var id = pageID();
            var installed = !!id && state.installed.indexOf(id) >= 0;
            var busy = !!id && state.busy === id;
            setLabel(button, installed ? labels.added : (busy ? labels.adding : labels.add));
            button.disabled = installed || busy;
            button.setAttribute('aria-disabled', button.disabled ? 'true' : 'false');
            button.style.opacity = '';
            button.style.pointerEvents = '';
          }

          function renderAll() {
            var mine = document.querySelectorAll('button[data-cmux="add"]');
            for (var i = 0; i < mine.length; i++) render(mine[i]);
          }

          function mend() {
            hidePromotions();
            if (!pageID()) return;
            var original = storeButton();
            if (original && original.parentNode) {
              var ours = original.cloneNode(true);
              ['disabled', 'aria-disabled', 'jsaction', 'jscontroller', 'jsname', 'jslog', 'aria-describedby'].forEach(function (name) {
                ours.removeAttribute(name);
              });
              ours.dataset.cmux = 'add';
              original.dataset.cmux = 'store';
              original.style.display = 'none';
              original.parentNode.insertBefore(ours, original.nextSibling);
              handler.postMessage({ placed: true });
            }
            renderAll();
          }

          // Capture on window so the store's document-level handlers never
          // see the click.
          window.addEventListener('click', function (e) {
            var mine = e.target && e.target.closest && e.target.closest('button[data-cmux="add"]');
            if (!mine) return;
            e.preventDefault();
            e.stopImmediatePropagation();
            if (!mine.disabled && e.isTrusted) handler.postMessage({ add: true });
          }, true);

          window.__cmuxChromeWebStore = {
            state: function (next) {
              state = next || state;
              renderAll();
            }
          };

          // The store is a single-page app that redraws itself; mend after
          // each burst of mutations. A timer, not rAF: hidden tabs get no frames.
          var queued = false;
          new MutationObserver(function () {
            if (queued) return;
            queued = true;
            setTimeout(function () { queued = false; mend(); }, 60);
          }).observe(document.documentElement, { childList: true, subtree: true });
          mend();
        })();
        """
    }
}
