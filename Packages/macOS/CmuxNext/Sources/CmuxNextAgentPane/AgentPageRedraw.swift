public import AppKit
import CmuxNextPages
import CmuxNextWakeups

/// A chat shown again after another tab (cx-f6i7): its pane may have changed size meanwhile (the
/// strip hides when the tab over it closes), and the engine shows the page's last frame, at the old
/// size, until the page lays out again. The pane keeps what it showed until the page drew at the
/// size it shows at (`PanePaintHold`). It reaches the page only through the page host's
/// engine-neutral calls (``PageWebView/callPageFunction(_:arguments:)``, ``PageWebView/afterNextFrame(_:)``,
/// ``PageWebView/snapshot()``), so it works the same whichever engine shows the chat.
@MainActor
public final class AgentPageRedraw {
    /// The shared page host's view of the chat.
    private weak var page: PageWebView?
    /// The size the page last laid out at in a window.
    private var drawnSize: CGSize?
    private var waiters: [() -> Void] = []
    /// The frame wait on the way: nil once the page ran its frame callback or dropped it.
    private weak var frameWait: FrameWait?
    /// How a frame is asked of the page: ``PageWebView/afterNextFrame(_:)``.
    private let nextFrame: @MainActor (PageWebView, @escaping () -> Void) -> Void
    private var probing = false
    private var generation: UInt64 = 0

    init(page: PageWebView, nextFrame: @escaping @MainActor (PageWebView, @escaping () -> Void) -> Void = { $0.afterNextFrame($1) }) {
        self.page = page
        self.nextFrame = nextFrame
    }

    /// The bodies waiting for one page frame. Only the page's frame callback keeps them (Chromium's
    /// `base::OnceCallback` bound into the callback, base/functional/callback.h): a callback the page
    /// drops drops them too, so a `OnceContinuation` among them ends `.abandoned` instead of hanging.
    @MainActor
    private final class FrameWait {
        var bodies: [() -> Void] = []

        func finish() {
            let waiting = bodies
            bodies = []
            waiting.forEach { $0() }
        }
    }

    /// The frame-then-task wait in the page; `done` runs after it (now when the page is gone).
    private func probeFrame(_ done: @escaping @MainActor () -> Void) {
        let script = "await new Promise((done) => requestAnimationFrame(() => setTimeout(done, 0)));"
        guard page != nil else { return done() }
        // task-owner: one frame wait; ends with the page's answer
        // main-hop-allow: callPageFunction is the page host's main-actor async call (the engine's script round trip);
        // this task only starts it, and its one resume ends the wait the chat's show holds (PanePaintHold)
        Task { @MainActor [weak page] in
            _ = await page?.callPageFunction(script)
            done()
        }
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
        // visibility-walk-allow: the size the page draws at is what AppKit composites, and a pane parks a hidden page
        // (isHidden) while its tab stays selected, which a node does not say; one walk per pane layout
        guard pane.window != nil, !pane.bounds.isEmpty, !pane.isHiddenOrHasHiddenAncestor else { return }
        let size = pane.bounds.size
        guard size != drawnSize else {
            // Drawn at this size, or the frame that draws it is on the way.
            if !probing { finish() }
            return
        }
        drawnSize = size
        guard !waiters.isEmpty, page != nil else { return finish() }
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
    /// page, then (WebKit) the next presentation update the window shows, so a page moved into
    /// another view has drawn there (cx-21zkz: the page's task ran a few frames before). Now when
    /// the page is gone. Never when the page drops its frame callback: `body` is released then, and the
    /// next call asks the page for a frame again.
    public func afterNextFrame(_ body: @escaping () -> Void) {
        guard let page else { return body() }
        if let frameWait {
            frameWait.bodies.append(body)
            return
        }
        let wait = FrameWait()
        wait.bodies.append(body)
        frameWait = wait
        nextFrame(page) { [weak self] in
            if self?.frameWait === wait { self?.frameWait = nil }
            wait.finish()
        }
    }

    /// A capture for the app's New Tab frame is on the way (one per page at a time).
    public var givesNewTabFrame = false
    /// That capture's settle deadline, held while it is pending (``AgentPaneNewTabFrame/capture(_:in:)``).
    var newTabSettle: MainDeadline?

    /// The page as it drew out of sight (a parked New Tab spare), at its size and appearance.
    private var remembered: (image: NSImage, size: CGSize, appearance: NSAppearance.Name?, generation: UInt64)?

    /// Snapshots the page as it draws now in `pane` (a parked New Tab spare), kept when `pane` is
    /// still where and as large as it was when the snapshot is ready: the image its move into a pane
    /// shows until it draws there is then this page at that size.
    public func rememberFrame(of pane: NSView, appearance: NSAppearance.Name?) {
        // Only a page that draws today's chats and model (`AgentPaneNewTabFrame`).
        guard let model = (pane as? AgentPaneView)?.model, AgentPaneNewTabFrame.shared.shows(model).0 else { return }
        // A Chromium picture draws the page's clear areas black (``PageWebView/snapshotKeepsClearAreas``):
        // checked before and after, as the page can move to or from Chromium while its picture is taken.
        guard let page, page.snapshotKeepsClearAreas else { return }
        let (size, place, generation) = (pane.frame.size, pane.superview, AgentPaneNewTabFrame.shared.generation)
        // task-owner: one snapshot; dropped when the page moved or resized meanwhile
        // main-hop-allow: snapshot() is the page host's main-actor async picture (the engine's capture); this task only
        // starts it, and its one resume keeps the picture when the page is still where it was
        Task { @MainActor [weak self, weak page, weak pane, weak place] in
            guard let image = await page?.snapshot(), image.size == size, page?.snapshotKeepsClearAreas == true,
                  let pane, pane.superview === place, pane.frame.size == size else { return }
            self?.remembered = (image, size, appearance, generation)
        }
    }

    /// The remembered frame, once, when it was drawn at `size` and `appearance` and its chats and model
    /// are still today's (`AgentPaneNewTabFrame`).
    public func takeRememberedFrame(size: CGSize, appearance: NSAppearance.Name?) -> NSImage? {
        defer { remembered = nil }
        guard let remembered, remembered.size == size, remembered.appearance == appearance,
              remembered.generation == AgentPaneNewTabFrame.shared.generation else { return nil }
        return remembered.image
    }

    private func finish() {
        let waiting = waiters
        waiters = []
        waiting.forEach { $0() }
    }
}
