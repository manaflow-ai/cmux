#if DEBUG
public import CmuxNextSettings
public import Foundation
import AppKit
import ObjectiveC
import WebKit

/// The generic page debug verb (`debug.page {page, state | snapshot}`): what any page shows, read
/// from the DOM, and the page as WebKit rendered it. Absorbed from the Settings lead's
/// `debug.settings_web` (branch feat-cmux-next-settings-react).
extension PageWebView {
    /// URL fragment, visible text (first 400 characters), control count, the computed html and
    /// body backgrounds (the one-backdrop check), and the focused element with its value (typing
    /// checks).
    public func debugState() async -> JSONValue {
        let script = """
        return JSON.stringify({
          page: document.documentElement.dataset.cmuxPage || null,
          hash: location.hash,
          lang: document.documentElement.lang,
          text: (document.body && document.body.innerText || '').slice(0, 400),
          controls: document.querySelectorAll('input,select,button,[role=switch],[role=radio],[role=option]').length,
          html: getComputedStyle(document.documentElement).backgroundColor,
          body: document.body ? getComputedStyle(document.body).backgroundColor : null,
          active: document.activeElement && document.activeElement !== document.body
            ? { tag: document.activeElement.tagName.toLowerCase(), value: 'value' in document.activeElement ? String(document.activeElement.value) : null }
            : null
        });
        """
        guard let text = try? await webView.callAsyncJavaScript(script, contentWorld: .page) as? String,
              let value = try? JSONValue.parse(Data(text.utf8)) else { return ["error": "page not loaded"] }
        return value
    }

    /// Clicks the first element that matches the CSS `selector` (live GUI proofs drive a page
    /// control with no pointer). Returns whether an element matched.
    public func debugClick(_ selector: String) async -> Bool {
        let script = "const el = document.querySelector(selector); if (!el) { return false; } el.click(); return true;"
        let clicked = try? await webView.callAsyncJavaScript(script, arguments: ["selector": selector], contentWorld: .page)
        return clicked as? Bool == true
    }

    /// Writes the page as WebKit rendered it to `url` as PNG.
    public func debugSnapshot(to url: URL) async -> Bool {
        keepRenderingWhenCovered()
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// `-[WKWebView _setWindowOcclusionDetectionEnabled:]`, when this WebKit has it, so a tagged
    /// build behind other windows still renders.
    func keepRenderingWhenCovered() {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: SetEnabled.self)(webView, selector, false)
    }
}
#endif
