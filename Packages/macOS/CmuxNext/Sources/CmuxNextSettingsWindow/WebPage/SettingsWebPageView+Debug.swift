#if DEBUG
public import CmuxNextSettings
public import Foundation
import AppKit
import ObjectiveC
import WebKit

extension SettingsWebPageView {
    /// What the page shows, read from the DOM (`debug.settings_web state`):
    /// route, rendered row count, computed html/body backgrounds.
    public func debugState() async -> JSONValue {
        let script = """
        return JSON.stringify({
          hash: location.hash,
          ready: !!window.cmuxSettingsBridge,
          text: (document.body && document.body.innerText || '').slice(0, 400),
          controls: document.querySelectorAll('input,select,button,[role=switch],[role=radio]').length,
          html: getComputedStyle(document.documentElement).backgroundColor,
          body: document.body ? getComputedStyle(document.body).backgroundColor : null
        });
        """
        guard let text = try? await webView.callAsyncJavaScript(script, contentWorld: .page) as? String,
              let value = try? JSONValue.parse(Data(text.utf8)) else { return ["error": "page not loaded"] }
        return value
    }

    /// The page as rendered by WebKit, written as PNG to `url`
    /// (`debug.window_snapshot` draws WebKit content as its background).
    public func debugSnapshot(to url: URL) async -> Bool {
        keepRenderingWhenCovered()
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// `-[WKWebView _setWindowOcclusionDetectionEnabled:]`, when this WebKit
    /// has it, so a tagged build behind other windows still renders.
    func keepRenderingWhenCovered() {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: SetEnabled.self)(webView, selector, false)
    }
}
#endif
