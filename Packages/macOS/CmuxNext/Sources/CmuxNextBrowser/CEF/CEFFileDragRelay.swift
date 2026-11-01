import AppKit
import os

/// Files dragged in from another app (Finder) over a Chromium page reach the page as a real drop.
///
/// The fork's page window ignores the mouse once the pointer leaves it (`routeMouseAt:` in
/// `chrome_child_window_mac.mm`) and never changes that while a button is down, so a drag that
/// starts in another app always lands in cmux's window, not the page's: the page got no drop and an
/// upload zone never saw the file. The pane's `CEFHostView`, which the page window covers, takes
/// the drag and replays it to the page with DevTools `Input.dispatchDragEvent`, which Chromium runs
/// as the person's own drop (file access is granted for the dropped paths, as for a native drop).
/// When the page window does take a drag itself, Chromium handles it and this relay sees nothing.
@MainActor
final class CEFFileDragRelay {
    /// The tab the pane shows; nil refuses the drag. Setting it registers `view` for file drags, so
    /// a host view no pane drives (DevTools) leaves file drags to the views behind it.
    var target: (() -> CEFTab?)? {
        didSet { if target != nil { view?.registerForDraggedTypes([.fileURL]) } }
    }
    weak var view: NSView?

    /// The files of the current drag, read once when it enters (a pasteboard read per move lags).
    private var files: [URL] = []
    private var tab: CEFTab?
    /// The DevTools sends, in order: a later event waits for the one before it.
    private var chain: Task<Void, Never>?
    /// A dragOver waiting in the chain reads the newest point when it runs, so moves never pile up.
    private var pendingOver: CGPoint?
    /// The last point sent or queued (AppKit repeats updates while the pointer rests).
    private var lastPoint: CGPoint?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef.file-drag")

    /// Copy, link and move (DevTools `DragOperationsMask`), as Chrome offers a page a Finder drag.
    private static let operations = 1 | 2 | 16

    func entered(_ info: any NSDraggingInfo, at point: CGPoint) -> NSDragOperation {
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty, let tab = target?(), tab.browserID != nil else {
            reset()
            return []
        }
        files = urls
        self.tab = tab
        tab.pageFilesDragged?(urls)
        lastPoint = point
        send("dragEnter", at: point)
        return .copy
    }

    func updated(at point: CGPoint) -> NSDragOperation {
        guard tab != nil else { return [] }
        guard point != lastPoint else { return .copy }
        lastPoint = point
        if pendingOver == nil { send("dragOver", at: nil) }
        pendingOver = point
        return .copy
    }

    /// The drag left the page, or the session ended without a drop here.
    func exited() {
        guard let tab else { return }
        // DevTools has no dragLeave, and a move off the page fires none: the page's drop zones
        // hear one from a script (the element under the last point, bubbling), then the drag ends.
        pendingOver = nil
        if let lastPoint { leave(tab, at: lastPoint) }
        send("dragCancel", at: .zero)
        tab.pageDragEnded?(false)
        reset()
    }

    func dropped(at point: CGPoint) -> Bool {
        guard let tab else { return false }
        // The native drop, with its event in dispatch, before the page hears it: what backs the
        // page's drop message (page script can post one, but cannot make this).
        tab.pageDragEnded?(true)
        send("drop", at: point)
        reset()
        return true
    }

    private func reset() {
        files = []
        tab = nil
        pendingOver = nil
        lastPoint = nil
    }

    /// The tab's page coordinates (CSS pixels) of a view point: under a fit's or device's scale
    /// (cx-mogig) and the page zoom, which Chromium multiplies back in.
    private static func css(_ point: CGPoint, in tab: CEFTab) -> CGPoint {
        let scale = tab.emulationInputScale / max(tab.state.zoom, 0.01)
        return CGPoint(x: point.x * scale, y: point.y * scale)
    }

    /// Queues one DevTools drag event; `point` nil is the pending dragOver's newest point.
    private func send(_ type: String, at point: CGPoint?) {
        guard let tab else { return }
        let files = files.map(\.path)
        let previous = chain
        // `CEFTab.runtime` is `unowned`, and this Task suspends on `previous` before it calls into
        // the tab: the Task holds the tab strongly but nothing holds the runtime behind it, so it
        // is read here, while it is known alive, and the capture keeps it so for the call below
        // (see `CEFMediaBridge.run`). The tab's own methods are still the ones called; only the
        // runtime's lifetime changes.
        let runtime = tab.runtime
        chain = Task { [weak self, logger] in
            await previous?.value
            let at: CGPoint
            if let point {
                at = point
            } else {
                guard let over = self?.pendingOver else { return }
                self?.pendingOver = nil
                at = over
            }
            let css = Self.css(at, in: tab)
            do {
                _ = try await tab.devTools(method: "Input.dispatchDragEvent", params: [
                    "type": type, "x": css.x, "y": css.y,
                    "data": ["items": [[String: any Sendable]](), "files": files, "dragOperationsMask": Self.operations] as [String: any Sendable],
                ])
            } catch {
                logger.error("file drag \(type, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            withExtendedLifetime(runtime) {}
        }
    }

    /// Queues a `dragleave` for the element under `point` (and its ancestors).
    private func leave(_ tab: CEFTab, at point: CGPoint) {
        let css = Self.css(point, in: tab)
        let script = """
        (() => { const el = document.elementFromPoint(\(css.x), \(css.y)); if (!el) return false;
          el.dispatchEvent(new DragEvent('dragleave', {bubbles: true, cancelable: true, clientX: \(css.x), clientY: \(css.y)})); return true; })()
        """
        let previous = chain
        // Read before the Task for the same reason as `send`: the suspension on `previous` comes
        // before the call into the tab, and the tab does not keep its `unowned` runtime alive.
        let runtime = tab.runtime
        chain = Task { [logger] in
            await previous?.value
            do {
                _ = try await tab.evaluate(script, world: .isolated, gesture: .cmux)
            } catch {
                logger.error("file drag leave failed: \(String(describing: error), privacy: .public)")
            }
            withExtendedLifetime(runtime) {}
        }
    }
}

extension CEFHostView {
    /// The drag's location in the page: view points from the top left.
    private func pagePoint(_ info: any NSDraggingInfo) -> CGPoint {
        let local = convert(info.draggingLocation, from: nil)
        return CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileDrag.entered(sender, at: pagePoint(sender))
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileDrag.updated(at: pagePoint(sender))
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        fileDrag.exited()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        fileDrag.dropped(at: pagePoint(sender))
    }

    /// A session that ended with no exit or drop here (the view left its window mid-drag).
    // NSView has no `draggingEnded:` of its own: no super call.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        fileDrag.exited()
    }
}
