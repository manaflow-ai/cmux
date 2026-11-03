public import AppKit
import CmuxNextPages
import WebKit

/// A chat shown again after another tab (cx-f6i7): its pane may have changed size meanwhile (the
/// strip hides when the tab over it closes), and WebKit shows the page's last frame, at the old
/// size, until the page lays out again. The pane keeps what it showed until the page drew at the
/// size it shows at (`PanePaintHold`).
@MainActor
public final class AgentPageRedraw {
    private weak var webView: WKWebView?
    /// The shared page host's view, when the page shows there (either engine): its calls replace
    /// the WebKit ones.
    private weak var page: PageWebView?
    /// The size the page last laid out at in a window.
    private var drawnSize: CGSize?
    private var waiters: [() -> Void] = []
    private var frameWaiters: [() -> Void] = []
    private var probing = false
    private var generation: UInt64 = 0
    /// Tests drive capture completion without a window-server compositor. Nil uses the page's
    /// real frame and snapshot paths; neither override changes capture ownership or visibility.
    var nextFrameOverride: (@MainActor (@escaping () -> Void) -> Void)?
    var snapshotOverride: (@MainActor () async -> NSImage?)?

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// For a page on the shared page host, in whichever engine shows it.
    init(page: PageWebView) {
        self.page = page
        webView = page.webKitView
    }

    /// The frame-then-task wait in the page; `done` runs after it (now when the page is gone).
    private func probeFrame(_ done: @escaping @MainActor () -> Void) {
        let script = "await new Promise((done) => requestAnimationFrame(() => setTimeout(done, 0)));"
        if let page {
            // task-owner: one frame wait; ends with the page's answer
            Task { @MainActor [weak page] in
                _ = await page?.callPageFunction(script)
                done()
            }
            return
        }
        guard let webView else { return done() }
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { _ in done() }
    }

    /// The page drew before and shows again at another size than it drew at: out of the window, or
    /// parked hidden in its pane (the pane keeps it at the size it shows at meanwhile, which a window
    /// resize changes, but it draws nothing hidden), at a size that changed or is about to (the pane
    /// has a layout pending: the strip hides with this switch, cx-f6i7). Its own frame, not its
    /// host's: a chat sharing the tab row shows over the whole pane while the host behind a terminal
    /// is the area under the strip. Shown again at the size it drew at, it shows at once (perf-tabs).
    public func awaits(_ pane: NSView) -> Bool {
        guard let drawnSize else { return false }
        if pane.window == nil { return true }
        guard pane.isHidden, let host = pane.superview else { return false }
        return pane.frame.size != drawnSize || host.superview?.needsLayout == true || host.needsLayout
    }

    /// Runs `body` once the page drew at the size `pane` shows it at: at the pane's next layout when
    /// that is the size it last drew at, else after the page's next frame.
    public func when(_ pane: NSView, _ body: @escaping () -> Void) {
        waiters.append(body)
        pane.needsLayout = true
    }

    /// From the pane's `layout()`: notes the size the page draws at, and answers ``when(_:_:)``.
    func laidOut(_ pane: NSView) {
        // A hidden page follows the pane's size but draws nothing: its drawn size stays.
        guard pane.window != nil, !pane.bounds.isEmpty, !pane.isHiddenOrHasHiddenAncestor else { return }
        let size = pane.bounds.size
        guard size != drawnSize else {
            // Drawn at this size, or the frame that draws it is on the way.
            if !probing { finish() }
            return
        }
        drawnSize = size
        guard !waiters.isEmpty, page != nil || webView != nil else { return finish() }
        probing = true
        generation &+= 1
        let generation = generation
        // One animation frame, then a task: it runs after that frame was rendered (PagePaintProbe).
        probeFrame { [weak self] in
            guard let self, self.generation == generation else { return }
            self.probing = false
            self.finish()
        }
    }

    /// Runs `body` once the page's next frame is on screen: one animation frame and a task in the
    /// page, then WebKit's next presentation update (the layer tree the window shows), so a page
    /// moved into another view has drawn there (cx-21zkz: the page's task ran a few frames before).
    /// Now when it has no web view.
    public func afterNextFrame(_ body: @escaping () -> Void) {
        if let nextFrameOverride { return nextFrameOverride(body) }
        if let page {
            frameWaiters.append(body)
            guard frameWaiters.count == 1 else { return }
            page.afterNextFrame { [weak self] in self?.finishFrame() }
            return
        }
        guard webView != nil else { return body() }
        frameWaiters.append(body)
        guard frameWaiters.count == 1 else { return }
        probeFrame { [weak self] in
            self?.afterPresentationUpdate { [weak self] in self?.finishFrame() }
        }
    }

    /// A capture for the app's New Tab frame is on the way (one per page at a time).
    public var givesNewTabFrame = false {
        didSet {
            if givesNewTabFrame != oldValue { newTabFrameCaptureChanged?(givesNewTabFrame) }
        }
    }
    /// A parked spare wakes for a fresh cover capture and sleeps once it finishes. Its owner
    /// removes this callback on adoption or drop, so a late capture cannot hide an active page.
    public var newTabFrameCaptureChanged: ((Bool) -> Void)?

    /// The page as it drew out of sight (a parked New Tab spare), at its size and appearance.
    private var remembered: (image: NSImage, size: CGSize, appearance: NSAppearance.Name?, generation: UInt64)?

    /// The capture source shared by a parked page's remembered cover and the app's New Tab frame.
    func snapshot() async -> NSImage? {
        if let snapshotOverride { return await snapshotOverride() }
        if let page { return await page.snapshot() }
        return try? await webView?.takeSnapshot(configuration: nil)
    }

    /// Snapshots the page as WebKit draws it now in `pane` (a parked New Tab spare), kept when `pane`
    /// is still where and as large as it was when the snapshot is ready: the image its move into a
    /// pane shows until it draws there is then this page at that size.
    public func rememberFrame(of pane: NSView, appearance: NSAppearance.Name?, completion: @escaping @MainActor () -> Void = {}) {
        // Only a page that draws today's chats and model (`AgentPaneNewTabFrame`).
        guard let model = (pane as? AgentPaneView)?.model, AgentPaneNewTabFrame.shared.shows(model).0 else { return completion() }
        // A Chromium picture draws the page's clear areas black (``PageWebView/snapshotKeepsClearAreas``):
        // checked before and after, as the page can move to or from Chromium while its picture is taken.
        guard page?.snapshotKeepsClearAreas ?? true else { return completion() }
        let (size, place, generation) = (pane.frame.size, pane.superview, AgentPaneNewTabFrame.shared.generation)
        // task-owner: one snapshot; dropped when the page moved or resized meanwhile
        Task { @MainActor [weak self, weak page, weak pane, weak place] in
            defer { completion() }
            let image = await self?.snapshot()
            guard let image, image.size == size, page?.snapshotKeepsClearAreas ?? true,
                  let pane, pane.superview === place, pane.frame.size == size else { return }
            self?.remembered = (image, size, appearance, generation)
        }
    }

    /// Drops the remembered frame: the page's context changed, so the frame shows another screen.
    public func forgetRememberedFrame() { remembered = nil }

    /// The remembered frame, once, when it was drawn at `size` and `appearance` and its chats and model
    /// are still today's (`AgentPaneNewTabFrame`).
    public func takeRememberedFrame(size: CGSize, appearance: NSAppearance.Name?) -> NSImage? {
        defer { remembered = nil }
        guard let remembered, remembered.size == size, remembered.appearance == appearance,
              remembered.generation == AgentPaneNewTabFrame.shared.generation else { return nil }
        return remembered.image
    }

    private func afterPresentationUpdate(_ body: @escaping () -> Void) {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard let webView, webView.responds(to: selector) else { return body() }
        typealias Action = @convention(block) () -> Void
        // WebKit keeps the block until the update: it must be an escaping one.
        let action: Action = { body() }
        webView.perform(selector, with: action)
    }

    private func finishFrame() {
        let waiting = frameWaiters
        frameWaiters = []
        waiting.forEach { $0() }
    }

    private func finish() {
        let waiting = waiters
        waiters = []
        waiting.forEach { $0() }
    }
}
