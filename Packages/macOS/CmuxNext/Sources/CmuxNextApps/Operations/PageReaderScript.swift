import Foundation

/// The page side of `page.read`: a self-contained, readability-style script run in a browser tab
/// through `browser.page.eval`. It picks the page's main content (an `article` or `main`, else the
/// element whose paragraphs hold the most text with the fewest links), walks it in document order
/// into blocks (heading, paragraph, list item, quote, code, image), skipping navigation, asides,
/// forms and hidden elements, and lists the page's http(s) links. Every text and count is capped
/// (``maxBlocks`` blocks of at most ``maxBlockText`` characters, ``maxTotalText`` in all,
/// ``maxLinks`` links) so the answer stays far under the provider channel's limits.
/// Returns a JSON string: `{url, title, article: {title, byline, site, blocks}, links}`.
nonisolated extension PageAppOps {
    static let maxBlocks = 400
    static let maxBlockText = 4_000
    static let maxTotalText = 200_000
    static let maxLinks = 500

    static let readerScript = #"""
    (() => {
      const MAX_BLOCKS = \#(maxBlocks), MAX_BLOCK_TEXT = \#(maxBlockText), MAX_TOTAL_TEXT = \#(maxTotalText), MAX_LINKS = \#(maxLinks), MAX_LINK_TEXT = 200, MAX_HREF = 2048;
      const clean = (s) => String(s || '').replace(/\s+/g, ' ').trim();
      const cap = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
      const meta = (sel) => clean(document.querySelector(sel)?.getAttribute('content'));
      const httpURL = (raw) => {
        try {
          const u = new URL(raw, document.baseURI);
          return u.protocol === 'http:' || u.protocol === 'https:' ? u.href : null;
        } catch (e) { return null; }
      };
      const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'SVG', 'CANVAS', 'IFRAME', 'NAV', 'ASIDE',
        'FOOTER', 'FORM', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'DIALOG', 'MENU', 'CMUX-LINK-HINTS']);
      const UNLIKELY = /(^|[\s_-])(comment|comments|share|social|promo|sidebar|footer|masthead|navbar|nav|menu|related|recommend|advert|ads?|sponsor|cookie|consent|subscribe|newsletter|popup|modal|breadcrumbs?|toolbar|banner)([\s_-]|$)/i;
      const hidden = (el) => {
        if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
        const style = el.ownerDocument.defaultView?.getComputedStyle?.(el);
        return !!style && (style.display === 'none' || style.visibility === 'hidden');
      };
      const unlikely = (el) => {
        const role = el.getAttribute('role') || '';
        if (/^(navigation|banner|contentinfo|complementary|search|dialog|alertdialog|menu|menubar)$/.test(role)) return true;
        return UNLIKELY.test(((el.getAttribute('class') || '') + ' ' + (el.id || '')));
      };
      const textLength = (el) => clean(el.textContent).length;
      const linkDensity = (el) => {
        const total = textLength(el) || 1;
        let links = 0;
        for (const a of el.querySelectorAll('a')) links += textLength(a);
        return links / total;
      };

      // The main content: a lone article or main, else the best-scoring parent of paragraphs.
      const pickRoot = () => {
        const articles = [...document.querySelectorAll('article')].filter((a) => !hidden(a) && textLength(a) > 200);
        if (articles.length === 1) return articles[0];
        const main = document.querySelector('main, [role=main]');
        if (main && !hidden(main) && textLength(main) > 200 && articles.length === 0) return main;
        const scores = new Map();
        for (const p of document.querySelectorAll('p, pre, td, blockquote')) {
          const length = textLength(p);
          if (length < 25) continue;
          const score = 1 + (clean(p.textContent).match(/,/g) || []).length + Math.min(Math.floor(length / 100), 3);
          let parent = p.parentElement, level = 0;
          while (parent && level < 3) {
            if (parent === document.body || parent === document.documentElement) break;
            scores.set(parent, (scores.get(parent) || 0) + score / (level === 0 ? 1 : level * 2));
            parent = parent.parentElement;
            level++;
          }
        }
        let best = null, bestScore = 0;
        for (const [el, score] of scores) {
          if (unlikely(el) || hidden(el)) continue;
          const adjusted = score * (1 - linkDensity(el));
          if (adjusted > bestScore) { best = el; bestScore = adjusted; }
        }
        return best || main || articles[0] || document.body;
      };

      const root = pickRoot();
      const blocks = [];
      let total = 0;
      const push = (block) => {
        if (blocks.length >= MAX_BLOCKS || total >= MAX_TOTAL_TEXT) return false;
        block.text = cap(block.text, Math.min(MAX_BLOCK_TEXT, MAX_TOTAL_TEXT - total));
        total += block.text.length + (block.src ? block.src.length : 0);
        blocks.push(block);
        return true;
      };
      const walk = (el) => {
        if (blocks.length >= MAX_BLOCKS || total >= MAX_TOTAL_TEXT) return;
        const tag = el.tagName;
        if (SKIP_TAGS.has(tag) || (el !== root && (hidden(el) || (unlikely(el) && linkDensity(el) > 0.3)))) return;
        if (el !== root && tag === 'HEADER' && linkDensity(el) > 0.5) return;
        if (/^H[1-6]$/.test(tag)) {
          const text = clean(el.textContent);
          if (text) push({ kind: 'heading', text, level: Number(tag[1]) });
          return;
        }
        if (tag === 'P') {
          const text = clean(el.textContent);
          if (text) push({ kind: 'paragraph', text });
          for (const img of el.querySelectorAll('img')) walk(img);
          return;
        }
        if (tag === 'LI') {
          if (el.querySelector('p, ul, ol, pre, blockquote')) { for (const child of el.children) walk(child); return; }
          const text = clean(el.textContent);
          if (text && (linkDensity(el) < 0.9 || text.length > 40)) push({ kind: 'list_item', text });
          return;
        }
        if (tag === 'BLOCKQUOTE') {
          const text = clean(el.textContent);
          if (text) push({ kind: 'quote', text });
          return;
        }
        if (tag === 'PRE') {
          const text = String(el.textContent || '').replace(/\s+$/, '');
          if (text.trim()) push({ kind: 'code', text });
          return;
        }
        if (tag === 'IMG') {
          const src = httpURL(el.currentSrc || el.getAttribute('src') || '');
          const width = Number(el.getAttribute('width') || el.naturalWidth || 0);
          if (src && src.length <= MAX_HREF && !(width > 0 && width < 48)) {
            const caption = el.closest('figure')?.querySelector('figcaption');
            push({ kind: 'image', text: clean(el.getAttribute('alt') || caption?.textContent || ''), src });
          }
          return;
        }
        if (tag === 'FIGCAPTION') return;
        // A container: its children in order; text sitting directly in it is a paragraph.
        let loose = '';
        const flush = () => {
          const text = clean(loose);
          loose = '';
          if (text.length > 1) push({ kind: 'paragraph', text });
        };
        for (const node of el.childNodes) {
          if (node.nodeType === 3) { loose += node.textContent; continue; }
          if (node.nodeType !== 1) continue;
          if (/^(A|SPAN|EM|STRONG|B|I|U|CODE|SMALL|SUB|SUP|MARK|ABBR|TIME|CITE|Q|S|DEL|INS|KBD|VAR|BR|FONT)$/.test(node.tagName) && !node.querySelector('p, div, img, h1, h2, h3, h4, h5, h6, ul, ol, pre, blockquote')) {
            loose += node.tagName === 'BR' ? ' ' : node.textContent;
            continue;
          }
          flush();
          walk(node);
        }
        flush();
      };
      walk(root);

      const heading = root.querySelector('h1') || document.querySelector('h1');
      const title = cap(meta('meta[property="og:title"]') || clean(heading?.textContent) || clean(document.title), 500);
      const byline = cap(meta('meta[name="author"]') || clean(document.querySelector('[rel=author], [itemprop=author], .byline, .author')?.textContent), 200) || null;
      const site = cap(meta('meta[property="og:site_name"]') || meta('meta[name="application-name"]'), 200) || null;

      const links = [], seen = new Set();
      for (const a of document.querySelectorAll('a[href]')) {
        if (links.length >= MAX_LINKS) break;
        const href = httpURL(a.getAttribute('href'));
        if (!href || href.length > MAX_HREF || seen.has(href)) continue;
        if (a.closest('cmux-link-hints')) continue;
        seen.add(href);
        links.push({ text: cap(clean(a.getAttribute('aria-label') || a.textContent || a.title), MAX_LINK_TEXT), href });
      }
      return JSON.stringify({ url: cap(location.href, MAX_HREF), title: cap(clean(document.title), 500),
        article: { title, byline, site, blocks }, links });
    })()
    """#
}
