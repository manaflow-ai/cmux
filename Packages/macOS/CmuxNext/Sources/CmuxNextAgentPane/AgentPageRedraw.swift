public import AppKit
import WebKit

/// A chat shown again after another tab (cx-f6i7): its pane may have changed size meanwhile (the
/// strip hides when the tab over it closes), and WebKit shows the page's last frame, at the old
/// size, until the page lays out again. The pane keeps what it showed until the page drew at the
/// size it shows at (`PanePaintHold`).
@MainActor
public final class AgentPageRedraw {
    private weak var webView: WKWebView?
    /// The size the page last laid out at in a window.
    private var drawnSize: CGSize?
    private var waiters: [() -> Void] = []
    private var probing = false
    private var generation: UInt64 = 0

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// The page drew before and `pane` is out of the window: shown again, it draws once more first.
    public func awaits(_ pane: NSView) -> Bool {
        pane.window == nil && drawnSize != nil
    }

    /// Runs `body` once the page drew at the size `pane` shows it at: at the pane's next layout when
    /// that is the size it last drew at, else after the page's next frame.
    public func when(_ pane: NSView, _ body: @escaping () -> Void) {
        waiters.append(body)
        pane.needsLayout = true
    }

    /// From the pane's `layout()`: notes the size the page draws at, and answers ``when(_:_:)``.
    func laidOut(_ pane: NSView) {
        guard pane.window != nil, !pane.bounds.isEmpty else { return }
        let size = pane.bounds.size
        guard size != drawnSize else {
            // Drawn at this size, or the frame that draws it is on the way.
            if !probing { finish() }
            return
        }
        drawnSize = size
        guard !waiters.isEmpty, let webView else { return finish() }
        probing = true
        generation &+= 1
        let generation = generation
        // One animation frame, then a task: it runs after that frame was rendered (PagePaintProbe).
        webView.callAsyncJavaScript(
            "await new Promise((done) => requestAnimationFrame(() => setTimeout(done, 0)));",
            arguments: [:], in: nil, in: .defaultClient
        ) { [weak self] _ in
            guard let self, self.generation == generation else { return }
            self.probing = false
            self.finish()
        }
    }

    private func finish() {
        let waiting = waiters
        waiters = []
        waiting.forEach { $0() }
    }
}
