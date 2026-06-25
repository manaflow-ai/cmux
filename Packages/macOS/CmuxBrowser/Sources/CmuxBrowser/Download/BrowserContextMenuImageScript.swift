public import CoreGraphics

/// A self-contained JavaScript snippet that inspects the DOM near a CSS-viewport point
/// to support browser context-menu image actions inside a `WKWebView`.
///
/// Each script is an immediately-invoked function expression evaluated against the page, with the
/// CSS-viewport `x`/`y` (already converted from the AppKit hit point by the caller) spliced in as
/// numeric literals. The script holds no `WKWebView` or app state; the caller owns the
/// `evaluateJavaScript` call and parses the string result into a URL.
///
/// ``resolveImageURL(at:)`` walks the element chain at the point (including `<picture>` siblings,
/// shadow roots, and `elementsFromPoint` overlays) and evaluates to the topmost image URL string,
/// or an empty string when none is found. ``debugInspectElements(at:)`` is a DEBUG-only inspection
/// snippet that evaluates to a JSON string describing the top elements at the point.
public struct BrowserContextMenuImageScript: Sendable, Equatable {
    /// The JavaScript source to evaluate in the page.
    public let source: String

    /// Wraps an already-formed JavaScript source string.
    /// - Parameter source: The JS source to evaluate.
    public init(source: String) {
        self.source = source
    }

    /// A script that resolves the topmost image URL near `point`, accounting for overlay layers.
    ///
    /// Evaluates to the resolved image URL string, or an empty string when no image is found at
    /// the point. The caller parses the result into a `URL`.
    /// - Parameter point: The CSS-viewport point (already converted from the AppKit hit point).
    /// - Returns: The image-resolution script.
    public static func resolveImageURL(at point: CGPoint) -> BrowserContextMenuImageScript {
        BrowserContextMenuImageScript(source: """
        (() => {
            const x = \(point.x);
            const y = \(point.y);
            const normalize = (raw) => {
                if (!raw || typeof raw !== 'string') return '';
                const trimmed = raw.trim();
                if (!trimmed) return '';
                if (trimmed.startsWith('//')) return window.location.protocol + trimmed;
                return trimmed;
            };
            const firstSrcsetURL = (srcset) => {
                if (!srcset || typeof srcset !== 'string') return '';
                const first = srcset.split(',').map((part) => part.trim()).find(Boolean);
                if (!first) return '';
                const urlPart = first.split(/\\s+/)[0];
                return normalize(urlPart);
            };
            const firstBackgroundURL = (value) => {
                if (!value || value === 'none') return '';
                const match = /url\\((['"]?)(.*?)\\1\\)/.exec(value);
                if (!match || !match[2]) return '';
                return normalize(match[2]);
            };
            const collectChain = (start) => {
                const out = [];
                const seen = new Set();
                const pushParents = (node) => {
                    while (node && !seen.has(node)) {
                        seen.add(node);
                        out.push(node);
                        node = node.parentElement;
                    }
                };
                pushParents(start);
                if (start && start.tagName === 'PICTURE' && start.querySelector) {
                    const img = start.querySelector('img');
                    if (img) pushParents(img);
                }
                return out;
            };
            const candidateFromElement = (el) => {
                if (!el) return '';
                const attr = (name) => normalize(el.getAttribute ? el.getAttribute(name) : '');
                if (el.tagName === 'IMG') {
                    const imageCandidates = [
                        normalize(el.currentSrc || ''),
                        attr('src'),
                        firstSrcsetURL(attr('srcset')),
                        attr('data-src'),
                        attr('data-iurl'),
                        attr('data-lazy-src'),
                        attr('data-original'),
                    ];
                    const foundImage = imageCandidates.find(Boolean);
                    if (foundImage) return foundImage;
                }
                const genericAttrs = [
                    'src', 'data-src', 'data-iurl', 'data-lazy-src',
                    'data-original', 'data-image', 'data-image-url',
                    'data-thumb', 'data-thumbnail-url', 'content'
                ];
                for (const name of genericAttrs) {
                    const v = attr(name);
                    if (v) return v;
                }
                const inlineBg = firstBackgroundURL(el.style && el.style.backgroundImage ? el.style.backgroundImage : '');
                if (inlineBg) return inlineBg;
                try {
                    const computed = window.getComputedStyle(el);
                    const computedBg = firstBackgroundURL(computed ? computed.backgroundImage : '');
                    if (computedBg) return computedBg;
                } catch (_) {}
                if (el.querySelector) {
                    const nestedImg = el.querySelector('img[src],img[srcset],img[data-src],img[data-iurl],source[srcset]');
                    if (nestedImg) {
                        const nestedCandidates = [
                            normalize(nestedImg.currentSrc || ''),
                            normalize(nestedImg.getAttribute ? nestedImg.getAttribute('src') : ''),
                            firstSrcsetURL(nestedImg.getAttribute ? nestedImg.getAttribute('srcset') : ''),
                            normalize(nestedImg.getAttribute ? (nestedImg.getAttribute('data-src') || nestedImg.getAttribute('data-iurl') || '') : '')
                        ];
                        const foundNested = nestedCandidates.find(Boolean);
                        if (foundNested) return foundNested;
                    }
                    const nestedBg = el.querySelector('[style*="background-image"]');
                    if (nestedBg) {
                        const styleValue = nestedBg.getAttribute ? nestedBg.getAttribute('style') : '';
                        const bgURL = firstBackgroundURL(styleValue || '');
                        if (bgURL) return bgURL;
                    }
                }
                return '';
            };
            const tryNodes = (nodes) => {
                for (const start of nodes) {
                    for (const el of collectChain(start)) {
                        const found = candidateFromElement(el);
                        if (found) return found;
                    }
                    if (start && start.shadowRoot && start.shadowRoot.elementFromPoint) {
                        const inner = start.shadowRoot.elementFromPoint(x, y);
                        if (inner) {
                            for (const el of collectChain(inner)) {
                                const found = candidateFromElement(el);
                                if (found) return found;
                            }
                        }
                    }
                }
                return '';
            };
            const all = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
            const foundFromAll = tryNodes(all);
            if (foundFromAll) return foundFromAll;
            const single = document.elementFromPoint ? document.elementFromPoint(x, y) : null;
            return candidateFromElement(single) || '';
        })();
        """)
    }

    /// A DEBUG-only script that inspects the top elements at `point` for context-download tracing.
    ///
    /// Evaluates to a JSON string of the shape `{"count":N,"entries":[...]}` describing up to eight
    /// elements at the point (tag, id, class, href, src, currentSrc, data-href, data-src). The caller
    /// logs the payload; it never affects the page or a download decision.
    /// - Parameter point: The CSS-viewport point (already converted from the AppKit hit point).
    /// - Returns: The element-inspection script.
    public static func debugInspectElements(at point: CGPoint) -> BrowserContextMenuImageScript {
        BrowserContextMenuImageScript(source: """
        (() => {
            const clip = (value, max = 180) => {
                if (value == null) return '';
                const s = String(value);
                return s.length > max ? s.slice(0, max) + '…' : s;
            };
            const x = \(point.x);
            const y = \(point.y);
            const nodes = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
            const entries = [];
            const limit = Math.min(nodes.length, 8);
            for (let i = 0; i < limit; i++) {
                const el = nodes[i];
                if (!el) continue;
                entries.push({
                    tag: clip((el.tagName || '').toLowerCase()),
                    id: clip(el.id || ''),
                    cls: clip(typeof el.className === 'string' ? el.className : ''),
                    href: clip(el.href || ''),
                    src: clip(el.src || ''),
                    currentSrc: clip(el.currentSrc || ''),
                    dataHref: clip(el.getAttribute ? el.getAttribute('data-href') : ''),
                    dataSrc: clip(el.getAttribute ? el.getAttribute('data-src') : '')
                });
            }
            return JSON.stringify({count: nodes.length, entries});
        })();
        """)
    }
}
