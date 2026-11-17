import Foundation

/// The Chrome Web Store's install buttons name the browser they install into: "Add to Chrome",
/// "Remove from Chrome". In cmux they install into cmux (the store's own install path,
/// `webstorePrivate`), so they read "Add to cmux" and "Remove from cmux" (Lawrence 2026-11-16).
///
/// A document-start script in its own world on https://chromewebstore.google.com only (every
/// other page returns at its first line). It renames the browser in `<button>` labels only:
/// text, `aria-label` and `title`. Item descriptions, "Chrome Web Store" and "Chrome Enterprise"
/// keep their words, and so does a button that offers Chrome itself ("Install Chrome"). It watches the document from its start, so the server-rendered button, the
/// store's re-renders (installed state, SPA navigation to another item) and its in-place text
/// changes are renamed in the same task that made them, before a frame paints: no flash of the
/// old label. Locales: the store keeps the brand "Chrome" in Latin letters in its translations
/// ("Zu Chrome hinzufügen", "Chrome に追加"), so the same rename works there; a translation that
/// spells the brand otherwise keeps the store's own text.
///
/// The store's two "switch to Chrome" prompts are not hidden here: the banner ("Switch to Chrome
/// to install extensions and themes") and the Google bar's "Switch to Chrome?" card are answers of
/// Google's servers that the shim turns off with the headers Google Chrome sends
/// (`CEFShim/src/webstore_headers.h`).
nonisolated enum BrowserWebStoreLabels {
    static let world = "cmuxWebStore"
    static let host = "chromewebstore.google.com"
    static let brand = "cmux"

    static let source = """
    (() => {
      if (location.protocol !== 'https:' || location.hostname !== '\(host)') return;
      const brand = /\\b(?:Google )?Chrome\\b(?!\\s*(?:Web\\s*Store|Enterprise|OS\\b|Remote|Beta|Dev\\b|Canary))/g;
      // A button that offers Chrome itself ("Install Chrome") keeps its words: it is about Chrome.
      const aboutChrome = /\\b(?:Install|Download|Get|Switch to)\\s+(?:Google\\s+)?Chrome\\b/i;
      const rename = (text) => aboutChrome.test(text) ? text : text.replace(brand, '\(brand)');
      const fixText = (node) => {
        const text = node.nodeValue;
        if (!text || !text.includes('Chrome')) return;
        const renamed = rename(text);
        if (renamed !== text) node.nodeValue = renamed;
      };
      const fixAttributes = (button) => {
        for (const name of ['aria-label', 'title']) {
          const text = button.getAttribute(name);
          if (!text || !text.includes('Chrome')) continue;
          const renamed = rename(text);
          if (renamed !== text) button.setAttribute(name, renamed);
        }
      };
      const fixButton = (button) => {
        fixAttributes(button);
        const walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) fixText(node);
      };
      const buttonOf = (node) => {
        const element = node.nodeType === 1 ? node : node.parentElement;
        return element ? element.closest('button') : null;
      };
      const fixAdded = (node) => {
        if (node.nodeType === 3) {
          if (node.nodeValue && node.nodeValue.includes('Chrome') && buttonOf(node)) fixText(node);
          return;
        }
        if (node.nodeType !== 1 && node.nodeType !== 9 && node.nodeType !== 11) return;
        const inside = node.nodeType === 1 ? buttonOf(node) : null;
        if (inside) { fixButton(inside); return; }
        if (node.querySelectorAll) for (const button of node.querySelectorAll('button')) fixButton(button);
      };
      const observer = new MutationObserver((records) => {
        for (const record of records) {
          if (record.type === 'childList') {
            for (const node of record.addedNodes) fixAdded(node);
          } else if (record.type === 'characterData') {
            if (record.target.nodeValue && record.target.nodeValue.includes('Chrome') && buttonOf(record.target)) fixText(record.target);
          } else if (record.target.nodeType === 1 && record.target.localName === 'button') {
            fixAttributes(record.target);
          }
        }
      });
      observer.observe(document, {
        subtree: true, childList: true, characterData: true,
        attributes: true, attributeFilter: ['aria-label', 'title'],
      });
      fixAdded(document);
    })();
    """
}
