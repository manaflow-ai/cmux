/// A CSS-viewport point that the browser context menu probes the DOM at, holding
/// the two JavaScript source strings cmux evaluates near a right-click location.
///
/// The owning AppKit `CmuxWebView` (app side) still converts the AppKit event
/// location into a CSS viewport point (``cssViewportPoint(for:)``) and owns the
/// WebKit evaluation seam; it builds one of these value-typed probes from the
/// resolved point and reads back the script text. Each script is byte-identical
/// to the source the corresponding `findImageURLAtPoint`/`debugInspectElementsAtPoint`
/// method previously assembled inline in `CmuxWebView`; only the static source
/// strings moved here, so the evaluated behavior is unchanged.
public struct BrowserContextMenuPointProbe: Sendable {
    /// The CSS-viewport x coordinate the probe runs at.
    public let x: Double
    /// The CSS-viewport y coordinate the probe runs at.
    public let y: Double

    /// Builds a probe at a CSS-viewport point.
    /// - Parameters:
    ///   - x: the CSS-viewport x coordinate.
    ///   - y: the CSS-viewport y coordinate.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Script that resolves the topmost image URL near the point, walking the
    /// `elementsFromPoint` stack (plus shadow roots and `<picture>` chains) and
    /// every common image attribute, lazy-load attribute, and CSS background-image
    /// declaration. Evaluates to the resolved URL string, or `''` when none is found.
    public var imageURLResolverScript: String {
        """
        (() => {
            const x = \(x);
            const y = \(y);
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
        """
    }

    /// Debug-only inspector script that reports the top 8 elements in the
    /// `elementsFromPoint` stack at the point, each clipped to 180 characters,
    /// as a JSON `{count, entries}` payload. Used only by the `#if DEBUG`
    /// context-download tracing in `CmuxWebView`.
    public var elementStackInspectorScript: String {
        """
        (() => {
            const clip = (value, max = 180) => {
                if (value == null) return '';
                const s = String(value);
                return s.length > max ? s.slice(0, max) + '…' : s;
            };
            const x = \(x);
            const y = \(y);
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
        """
    }
}
