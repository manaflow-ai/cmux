import CmuxNextWakeups
import WebKit

/// Counts a VoiceOver press on a WebKit page as the person's gesture (manaflow-ai/cmux#37809).
///
/// A page runs a person-only op only after a key or mouse event the host saw (``PageWKWebView``'s
/// `noteUserEvent`). A VoiceOver press (AXPress) sends neither: VoiceOver talks to WebKit's web
/// content process, whose accessibility tree it is, and the press never passes through the app's
/// `NSView`s, so no override on ``PageWKWebView`` sees it. In the web process the press is
/// `AccessibilityObject::press()`, which dispatches a click from the user agent
/// (`dispatchSimulatedClick(nullptr, SendMouseUpDownEvents)`, `SimulatedClickSource::UserAgent`): a
/// DOM click with `isTrusted` true. Page script cannot make such a click: `element.click()` and
/// `dispatchEvent` are untrusted, and a click WebKit forwards from an untrusted one (a label's click
/// on its control) is untrusted too (`Element::dispatchSimulatedClick`).
///
/// So a document-start script in a content world of its own (``world``) listens for trusted clicks
/// and posts to a handler only that world reaches (``handlerName``): the page's own script has no
/// `messageHandlers` entry for it and cannot fake `isTrusted`. The host counts the post as the
/// person's gesture only while VoiceOver runs (``PageWKWebView/noteAccessibilityPress(at:)``), with
/// the same one-second expiry as a mouse event; a page call spends it as it spends a click.
///
/// The cost: while VoiceOver runs, every trusted click in the page counts, a mouse click included,
/// which the mouse event already counted. A Chromium page has its own path
/// (`ChromiumAccessibilityPress`), so this script is left out of Chromium's document scripts.
enum PageAccessibilityPress {
    static let worldName = "cmux.accessibility-press"
    /// The content world of the press script: page script runs in `.page` and never sees it.
    @MainActor static var world: WKContentWorld { .world(name: worldName) }
    static let handlerName = "cmuxAccessibilityPress"

    /// Posts on each trusted click in the main frame's document, before the page's own handlers (capture on
    /// the window), so the gesture is recorded before the bridge call that click makes.
    static let script = """
    (() => {
      if (window.__cmuxAccessibilityPress) return;
      window.__cmuxAccessibilityPress = true;
      addEventListener("click", (event) => {
        if (!event.isTrusted) return;
        try { window.webkit.messageHandlers.\(handlerName).postMessage(1); } catch (_) {}
      }, true);
    })();
    """

    @MainActor static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    /// Installs the script and its handler on `webView`'s controller; `onPress` runs on each post.
    @MainActor static func install(on webView: WKWebView, onPress: @escaping @MainActor @Sendable () -> Void) {
        let controller = webView.configuration.userContentController
        controller.addUserScript(userScript)
        controller.add(Receiver(webView: webView, onPress: onPress), contentWorld: world, name: handlerName)
    }

    @MainActor static func uninstall(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
    }

    /// The user content controller retains its handlers, so this holds the web view weakly.
    private final class Receiver: NSObject, WKScriptMessageHandler {
        private weak var webView: WKWebView?
        let onPress: @MainActor @Sendable () -> Void

        init(webView: WKWebView, onPress: @escaping @MainActor @Sendable () -> Void) {
            self.webView = webView
            self.onPress = onPress
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only this view's main frame, from the press world (a view sharing the configuration is another page).
            guard let webView, message.webView === webView, message.frameInfo.isMainFrame,
                  message.world.name == PageAccessibilityPress.worldName else { return }
            // WebKit delivers on the main thread, in order with the page's bridge call that the same click makes.
            MainDelivery().run { [onPress] in onPress() }
        }
    }
}
