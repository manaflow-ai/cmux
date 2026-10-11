import Foundation
import WebKit

/// The first frame a page document painted (debug and preflights wait on it instead of a fixed
/// delay; the tab report says `painted` instead of `restoring`). A document-end script waits one
/// animation frame and then a task (it runs after that frame rendered), marks `<html>` with
/// `data-cmux-painted` (the page's own clock, ms) and tells the host, which keeps the monotonic
/// host time. A new document clears it (``PageWebView`` resets on commit).
enum PagePaintProbe {
    static let handlerName = "cmuxPagePainted"

    /// One animation frame, then a task: the task runs after that frame was rendered. Not two
    /// frames: WebKit stops animation frames once the window is occluded, so a second frame may
    /// never come although the first one drew (the nxdog32 report).
    static let script = """
    requestAnimationFrame(() => setTimeout(() => {
      const t = Math.round(performance.now());
      document.documentElement.dataset.cmuxPainted = String(t);
      try { window.webkit.messageHandlers.\(handlerName).postMessage(t); } catch (_) {}
    }, 0));
    """

    static func install(in controller: WKUserContentController, onPaint: @escaping @MainActor () -> Void) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        controller.add(Receiver(onPaint: onPaint), contentWorld: .page, name: handlerName)
    }

    private final class Receiver: NSObject, WKScriptMessageHandler {
        let onPaint: @MainActor () -> Void

        init(onPaint: @escaping @MainActor () -> Void) {
            self.onPaint = onPaint
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            let onPaint = onPaint
            Task { @MainActor in onPaint() }
        }
    }
}
