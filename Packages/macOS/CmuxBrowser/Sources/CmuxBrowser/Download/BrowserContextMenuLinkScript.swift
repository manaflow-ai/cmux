public import CoreGraphics

/// A self-contained JavaScript snippet that inspects the DOM near a CSS-viewport point
/// to support browser context-menu link actions inside a `WKWebView`.
///
/// Each script is an immediately-invoked function expression evaluated against the page, with the
/// CSS-viewport `x`/`y` (already converted from the AppKit hit point by the caller) spliced in as
/// numeric literals. The script holds no `WKWebView` or app state; the caller owns the
/// `evaluateJavaScript` call and parses the string result into a URL.
///
/// ``nearestAnchor(at:)`` walks the parent chain from the element at the point and evaluates to the
/// first `<a href>` URL string, or an empty string when none is found. It is the simple context-menu
/// download fallback. ``topmostLink(at:)`` walks the element chain at the point (including shadow
/// roots and `elementsFromPoint` overlays, and `href`/`data-*` link attributes) and evaluates to the
/// topmost link URL string, accounting for overlay layers, or an empty string when none is found.
public struct BrowserContextMenuLinkScript: Sendable, Equatable {
    /// The JavaScript source to evaluate in the page.
    public let source: String

    /// Wraps an already-formed JavaScript source string.
    /// - Parameter source: The JS source to evaluate.
    public init(source: String) {
        self.source = source
    }

    /// A script that finds the nearest anchor element at `point` by walking the parent chain.
    ///
    /// Evaluates to the first ancestor `<a>` element's `href`, or an empty string when none is found.
    /// The caller parses the result into a `URL`. Used as a context-menu download fallback.
    /// - Parameter point: The CSS-viewport point (already converted from the AppKit hit point).
    /// - Returns: The nearest-anchor script.
    public static func nearestAnchor(at point: CGPoint) -> BrowserContextMenuLinkScript {
        BrowserContextMenuLinkScript(source: """
        (() => {
            let el = document.elementFromPoint(\(point.x), \(point.y));
            while (el) {
                if (el.tagName === 'A' && el.href) return el.href;
                el = el.parentElement;
            }
            return '';
        })();
        """)
    }

    /// A script that resolves the topmost link URL near `point`, accounting for overlay layers.
    ///
    /// Evaluates to the resolved link URL string, or an empty string when no link is found at the
    /// point. The caller parses the result into a `URL`.
    /// - Parameter point: The CSS-viewport point (already converted from the AppKit hit point).
    /// - Returns: The topmost-link script.
    public static func topmostLink(at point: CGPoint) -> BrowserContextMenuLinkScript {
        BrowserContextMenuLinkScript(source: """
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
            const collectChain = (start) => {
                const out = [];
                const seen = new Set();
                while (start && !seen.has(start)) {
                    seen.add(start);
                    out.push(start);
                    start = start.parentElement;
                }
                return out;
            };
            const linkFromElement = (el) => {
                if (!el) return '';
                const attr = (name) => normalize(el.getAttribute ? el.getAttribute(name) : '');
                if (el.closest) {
                    const closestLink = el.closest('a[href],area[href]');
                    if (closestLink && closestLink.href) return normalize(closestLink.href);
                }
                if ((el.tagName === 'A' || el.tagName === 'AREA') && el.href) {
                    return normalize(el.href);
                }
                const attrCandidates = ['href', 'data-href', 'data-url', 'data-link', 'data-link-url'];
                for (const name of attrCandidates) {
                    const v = attr(name);
                    if (v) return v;
                }
                if (el.querySelector) {
                    const nestedLink = el.querySelector('a[href],area[href]');
                    if (nestedLink && nestedLink.href) return normalize(nestedLink.href);
                }
                return '';
            };
            const tryNodes = (nodes) => {
                for (const start of nodes) {
                    for (const node of collectChain(start)) {
                        const found = linkFromElement(node);
                        if (found) return found;
                    }
                    if (start && start.shadowRoot && start.shadowRoot.elementFromPoint) {
                        const inner = start.shadowRoot.elementFromPoint(x, y);
                        if (inner) {
                            for (const node of collectChain(inner)) {
                                const found = linkFromElement(node);
                                if (found) return found;
                            }
                        }
                    }
                }
                return '';
            };
            const nodes = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
            const found = tryNodes(nodes);
            if (found) return found;
            const single = document.elementFromPoint ? document.elementFromPoint(x, y) : null;
            return linkFromElement(single) || '';
        })();
        """)
    }
}
