public import AppKit
public import CmuxNextDesign
import CmuxNextWakeups
import WebKit

/// Presses on a page's own title row (https://github.com/manaflow-ai/cmux/issues/36897). A page
/// shown with no tab strip above it (a top page: Import history, Stats, the App Store) has the
/// window's title row over its top, and a press on the row's background there moves the window,
/// like the sidebar header beside it. AppKit cannot see the page's controls (a Chromium page is
/// even a child window), so the page reports the press: a document script tells the host about a
/// left press that starts a drag (moved 3 CSS px), or a double-click, on anything but a control in
/// its top 96 CSS px (the row at any page zoom down to 0.5). The page never sees the mouse-up of a
/// press the window took, so the host clears any selection the press began once the drag ends. The host checks the point is in the window's top row of a top page
/// (``TitleRowHostView/takesTitleRowPress(from:atWindowPoint:)``) and moves the window, or runs
/// the title bar's double-click action. A press on a control, below the row, or in a pane tab
/// stays the page's.
enum PageTitleRowPress {
    static let handlerName = "cmuxTitleRowPress"

    /// The press a page reported, at `point` in CSS px from the page's top left.
    nonisolated struct Report: Equatable, Sendable {
        enum Kind: String, Sendable { case drag, double }
        let kind: Kind
        let point: CGPoint
        /// The press was on the page's content (text, a picture), not its empty space.
        let onContent: Bool

        init(kind: Kind, point: CGPoint, onContent: Bool = false) {
            self.kind = kind
            self.point = point
            self.onContent = onContent
        }

        init?(_ body: Any) {
            guard let object = body as? [String: Any], let kind = (object["kind"] as? String).flatMap(Kind.init(rawValue:)),
                  let x = (object["x"] as? NSNumber)?.doubleValue, let y = (object["y"] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite else { return nil }
            self.init(kind: kind, point: CGPoint(x: x, y: y))
        }
    }

    /// The controls that keep their press, as `isTitleBar` in webviews/src/pages/shared/desktop.ts
    /// names them, plus ARIA widgets, focusable elements and an explicit `data-no-drag`.
    static let script = """
    (() => {
      if (window.__cmuxTitleRowPress) return;
      window.__cmuxTitleRowPress = true;
      const post = (message) => {
        try { window.webkit.messageHandlers.\(handlerName).postMessage(message); } catch (_) {}
      };
      const controls = 'button, input, textarea, select, a[href], label, summary, [role="button"], [role="tab"], ' +
        '[role="link"], [role="menuitem"], [role="checkbox"], [role="radio"], [role="switch"], [role="combobox"], ' +
        '[role="slider"], [role="textbox"], [contenteditable=""], [contenteditable="true"], ' +
        '[tabindex]:not([tabindex="-1"]), [data-no-drag]';
      let press = null;
      addEventListener("mousedown", (event) => {
        press = null;
        if (event.button !== 0 || event.clientY >= 96 || event.metaKey || event.ctrlKey) return;
        const target = event.target;
        if (!(target instanceof Element) || target.closest(controls) !== null) return;
        if (event.detail === 2) { post({ kind: "double", x: event.clientX, y: event.clientY }); return; }
        press = { x: event.clientX, y: event.clientY };
      }, true);
      addEventListener("mousemove", (event) => {
        if (press === null) return;
        if ((event.buttons & 1) === 0) { press = null; return; }
        if (Math.hypot(event.clientX - press.x, event.clientY - press.y) < 3) return;
        post({ kind: "drag", x: press.x, y: press.y });
        press = null;
      }, true);
      addEventListener("mouseup", () => { press = null; }, true);
    })();
    """

    static func install(in controller: WKUserContentController, onPress: @escaping @MainActor @Sendable (Report) -> Void) {
        controller.addUserScript(userScript)
        controller.add(Receiver(onPress: onPress), contentWorld: .page, name: handlerName)
    }

    static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    private final class Receiver: NSObject, WKScriptMessageHandler {
        let onPress: @MainActor @Sendable (Report) -> Void

        init(onPress: @escaping @MainActor @Sendable (Report) -> Void) {
            self.onPress = onPress
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let report = Report(message.body) else { return }
            // WebKit delivers on the main thread: the press runs in the same turn, while the button is down.
            MainDelivery().run { [onPress] in onPress(report) }
        }
    }
}

extension PageWebView: TitleRowSelfHandling {
    /// Where a page point (CSS px from its top left) is in the window.
    func windowPoint(forPagePoint point: CGPoint) -> CGPoint {
        let zoom = max(pageZoom, 0.01)
        let y = point.y * zoom
        return convert(CGPoint(x: point.x * zoom, y: isFlipped ? y : bounds.height - y), to: nil)
    }

    /// Whether the window takes `report` (a top page's title row), without acting on it.
    func takesTitleRowPress(_ report: PageTitleRowPress.Report) -> Bool {
        TitleRowHostView.takesTitleRowPress(from: self, atWindowPoint: windowPoint(forPagePoint: report.point))
    }

    /// A press the page reported on its title row (``PageTitleRowPress``): moves the window while
    /// the left button is still down, or runs the double-click action.
    func titleRowPressed(_ report: PageTitleRowPress.Report) {
        // Page script can post at any time: only right after the person's own press in the page.
        guard let window, recentUserGestureEvent(within: 0.5) != nil, takesTitleRowPress(report) else { return }
        switch report.kind {
        case .double:
            WindowTitlebar.performDoubleClick(in: window)
        case .drag:
            // Only a press the person still holds moves the window.
            guard NSEvent.pressedMouseButtons & 1 != 0,
                  let press = NSEvent.mouseEvent(with: .leftMouseDown, location: window.mouseLocationOutsideOfEventStream,
                                                 modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { return }
            window.performDrag(with: press) // returns once the button is up
            evaluateInPage("getSelection()?.removeAllRanges()")
        }
    }
}
