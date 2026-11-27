import AppKit
import WebKit

/// Web pages in hint mode (``WindowHintController``): a web view's
/// accessibility tree lives in its web content process, so each shown page
/// is asked instead. A script in an isolated world (never the page's own
/// scripts) lists the page's clickable elements in the viewport. Ported from
/// cmux-next's link hints.
@MainActor
enum WindowHintPages {
    /// How long the pages may take to list their targets; a busy page is left out.
    static let deadline: TimeInterval = 0.35

    /// The shown web views under `view`, in subview order.
    static func webViews(in view: NSView) -> [WKWebView] {
        guard !view.isHidden, view.alphaValue > 0.01 else { return [] }
        if let page = view as? WKWebView {
            return page.visibleRect.width > 0 && page.visibleRect.height > 0 ? [page] : []
        }
        return view.subviews.flatMap(webViews(in:))
    }

    /// The clickable elements of `pages`, in window coordinates and page
    /// order. Pages that have not answered by ``deadline`` are left out.
    static func targets(of pages: [WKWebView], clip: CGRect) async -> [WindowHintTargets.Target] {
        guard !pages.isEmpty else { return [] }
        let collection = PageCollection(count: pages.count)
        return await withCheckedContinuation { continuation in
            collection.continuation = continuation
            for (index, page) in pages.enumerated() {
                Task { @MainActor in
                    let value = try? await page.callAsyncJavaScript("return " + collectScript, arguments: [:],
                                                                    in: nil, contentWorld: .defaultClient)
                    collection.answer(index, targets((value as? String) ?? "[]", in: page, clip: clip))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
                MainActor.assumeIsolated { collection.finish() }
            }
        }
    }

    /// One page's script result (CSS pixels from its viewport's top left)
    /// in window coordinates.
    private static func targets(_ json: String, in page: WKWebView, clip: CGRect) -> [WindowHintTargets.Target] {
        struct Element: Decodable {
            var x: Double, y: Double, left: Double, top: Double
            var text: String?
        }
        guard let elements = try? JSONDecoder().decode([Element].self, from: Data(json.utf8)) else { return [] }
        let zoom = page.pageZoom * page.magnification
        let visible = page.convert(page.visibleRect, to: nil)
        func point(_ x: Double, _ y: Double) -> NSPoint {
            let local = NSPoint(x: x * zoom, y: page.isFlipped ? y * zoom : page.bounds.height - y * zoom)
            return page.convert(local, to: nil)
        }
        return elements.compactMap { element in
            // The script gives the top-left corner and the center; the far corner mirrors the first.
            let near = point(element.left, element.top), far = point(2 * element.x - element.left, 2 * element.y - element.top)
            let rect = CGRect(x: min(near.x, far.x), y: min(near.y, far.y), width: abs(far.x - near.x),
                              height: abs(far.y - near.y)).intersection(clip).intersection(visible)
            guard rect.width >= 4, rect.height >= 4 else { return nil }
            return WindowHintTargets.Target(rect: rect, role: "web", title: element.text ?? "",
                                            page: WindowHintPageElement(webView: page, x: element.x, y: element.y))
        }
    }

    /// Returns a JSON string: `[{x, y, left, top, text}]` (CSS pixels in
    /// the viewport; `text` names the element), at most 1000, in document
    /// order. Hidden, disabled and covered elements are skipped.
    static let collectScript = """
    (() => {
      const selector = 'a[href],area[href],button,input:not([type=hidden]),select,textarea,summary,label[for],' +
        '[role=button],[role=link],[role=checkbox],[role=radio],[role=switch],[role=tab],[role=menuitem],[role=option],' +
        '[onclick],[contenteditable=""],[contenteditable=true],[tabindex]:not([tabindex="-1"])';
      const width = innerWidth, height = innerHeight, out = [];
      for (const element of document.querySelectorAll(selector)) {
        if (element.disabled || element.closest('[inert],[aria-hidden=true]')) continue;
        const rect = Array.from(element.getClientRects()).find((r) =>
          r.width > 2 && r.height > 2 && r.bottom > 0 && r.right > 0 && r.top < height && r.left < width);
        if (!rect) continue;
        const style = getComputedStyle(element);
        if (style.visibility === 'hidden' || Number(style.opacity) === 0) continue;
        const left = Math.max(rect.left, 0), top = Math.max(rect.top, 0);
        const x = (left + Math.min(rect.right, width)) / 2, y = (top + Math.min(rect.bottom, height)) / 2;
        const hit = document.elementFromPoint(x, y);
        if (!hit || !(hit === element || element.contains(hit) || hit.contains(element))) continue;
        const named = (element.getAttribute('aria-labelledby') || '').split(/\\s+/)
          .map((id) => document.getElementById(id)?.innerText || '').join(' ').trim();
        const text = (element.getAttribute('aria-label') || named || element.labels?.[0]?.innerText || element.title ||
          element.innerText || element.value || '').toString().trim().slice(0, 80);
        out.push({ x: Math.round(x), y: Math.round(y), left: Math.round(left), top: Math.round(top), text });
        if (out.length >= 1000) break;
      }
      return JSON.stringify(out);
    })()
    """
}

/// The pages' answers for ``WindowHintPages/targets(of:clip:)``, kept in
/// page order, and the one resume of its continuation.
@MainActor
private final class PageCollection {
    var continuation: CheckedContinuation<[WindowHintTargets.Target], Never>?
    private var answers: [[WindowHintTargets.Target]?]

    init(count: Int) { answers = Array(repeating: nil, count: count) }

    func answer(_ index: Int, _ targets: [WindowHintTargets.Target]) {
        answers[index] = targets
        if answers.allSatisfy({ $0 != nil }) { finish() }
    }

    func finish() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: answers.compactMap { $0 }.flatMap { $0 })
    }
}

/// One page element hint mode labels, clicked inside its page: a web view
/// drops the first click of a window that is not key, and a page element
/// needs no mouse position. Equal by identity.
@MainActor
final class WindowHintPageElement: Equatable {
    private weak var webView: WKWebView?
    /// CSS pixels in the page's viewport.
    private let x: Double, y: Double

    init(webView: WKWebView, x: Double, y: Double) {
        self.webView = webView
        self.x = x
        self.y = y
    }

    nonisolated static func == (lhs: WindowHintPageElement, rhs: WindowHintPageElement) -> Bool { lhs === rhs }

    /// Focuses and clicks the element at the point, as a click does; `menu`
    /// asks it for its context menu instead. The page takes the keyboard.
    func click(menu: Bool) {
        guard let webView else { return }
        if !menu { webView.window?.makeFirstResponder(webView) }
        webView.callAsyncJavaScript(Self.clickScript, arguments: ["x": x, "y": y, "menu": menu],
                                    in: nil, in: .defaultClient, completionHandler: nil)
    }

    private static let clickScript = """
        const hit = document.elementFromPoint(x, y);
        if (!hit) return false;
        const element = hit.closest('a,button,input,select,textarea,summary,label,[role],[onclick],[tabindex],[contenteditable]') || hit;
        if (menu) {
          return element.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 2 }));
        }
        if (typeof element.focus === 'function') element.focus();
        element.click();
        return true;
        """
}
