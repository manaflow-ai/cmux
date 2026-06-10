import AppKit
import Bonsplit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Link and image hit testing via injected JS
extension CmuxWebView {
    private func resolveGoogleRedirectURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), host.contains("google.") else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = comps.queryItems else { return nil }
        let map = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name.lowercased(), $0.value ?? "") })
        let candidates = ["imgurl", "mediaurl", "url", "q"]
        for key in candidates {
            guard let raw = map[key], !raw.isEmpty,
                  let decoded = raw.removingPercentEncoding ?? raw as String?,
                  let candidate = URL(string: decoded),
                  isDownloadableScheme(candidate) else {
                continue
            }
            return candidate
        }
        // Some links are wrapped as /url?...
        if comps.path.lowercased() == "/url" {
            for key in ["url", "q"] {
                if let raw = map[key], let candidate = URL(string: raw), isDownloadableScheme(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    func normalizedLinkedDownloadURL(_ url: URL) -> URL {
        resolveGoogleRedirectURL(url) ?? url
    }

    func isLikelyImageURL(_ url: URL) -> Bool {
        if isDataURLScheme(url) {
            guard let parsed = Self.parseDataURL(url),
                  let mime = parsed.mimeType?.lowercased() else {
                return false
            }
            return mime.hasPrefix("image/")
        }
        guard isDownloadableScheme(url) else { return false }
        let ext = url.pathExtension.lowercased()
        if [
            "jpg", "jpeg", "png", "webp", "gif", "bmp",
            "svg", "avif", "heic", "heif", "tif", "tiff", "ico"
        ].contains(ext) {
            return true
        }
        let lower = url.absoluteString.lowercased()
        if lower.contains("imgurl=")
            || lower.contains("mediaurl=")
            || lower.contains("encrypted-tbn")
            || lower.contains("format=jpg")
            || lower.contains("format=jpeg")
            || lower.contains("format=png")
            || lower.contains("format=webp")
            || lower.contains("format=gif") {
            return true
        }
        return false
    }

    /// Resolve the topmost image URL near a point, accounting for overlay layers.
    func findImageURLAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let flippedY = bounds.height - point.y
        let js = """
        (() => {
            const x = \(point.x);
            const y = \(flippedY);
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
        evaluateJavaScript(js) { result, _ in
            guard let src = result as? String, !src.isEmpty,
                  let url = URL(string: src) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    /// Resolve the topmost link URL near a point, accounting for overlay layers.
    func findLinkURLAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let flippedY = bounds.height - point.y
        let js = """
        (() => {
            const x = \(point.x);
            const y = \(flippedY);
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
        """
        evaluateJavaScript(js) { result, _ in
            guard let href = result as? String, !href.isEmpty,
                  let url = URL(string: href) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    func debugInspectElementsAtPoint(_ point: NSPoint, traceID: String, kind: String) {
#if DEBUG
        let flippedY = bounds.height - point.y
        let js = """
        (() => {
            const clip = (value, max = 180) => {
                if (value == null) return '';
                const s = String(value);
                return s.length > max ? s.slice(0, max) + '…' : s;
            };
            const x = \(point.x);
            const y = \(flippedY);
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
        evaluateJavaScript(js) { [weak self] result, _ in
            guard let self,
                  let payload = result as? String,
                  !payload.isEmpty else { return }
            self.debugContextDownload(
                "browser.ctxdl.inspect trace=\(traceID) kind=\(kind) payload=\(payload)"
            )
        }
#endif
    }

}
