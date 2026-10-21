import AppKit

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
    /// The tab the pane shows; nil refuses the drag.
    var target: (() -> CEFTab?)?

    /// The files of the current drag, read once when it enters (a pasteboard read per move lags).
    private var files: [URL] = []
    private var tab: CEFTab?
    /// The DevTools sends, in order: a later event waits for the one before it.
    private var chain: Task<Void, Never>?
    /// A dragOver waiting in the chain reads the newest point when it runs, so moves never pile up.
    private var pendingOver: CGPoint?

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
        send("dragEnter", at: point)
        return .copy
    }

    func updated(at point: CGPoint) -> NSDragOperation {
        guard tab != nil else { return [] }
        if pendingOver != nil {
            pendingOver = point
        } else {
            pendingOver = point
            send("dragOver", at: nil)
        }
        return .copy
    }

    func exited() {
        guard tab != nil else { return }
        // DevTools has no dragLeave: a move off the page ends the page's hover (dragleave), then the drag ends.
        pendingOver = nil
        send("dragOver", at: CGPoint(x: -1, y: -1))
        send("dragCancel", at: .zero)
        reset()
    }

    func dropped(at point: CGPoint) -> Bool {
        guard tab != nil else { return false }
        send("drop", at: point)
        reset()
        return true
    }

    private func reset() {
        files = []
        tab = nil
        pendingOver = nil
    }

    /// Queues one DevTools drag event; `point` nil is the pending dragOver's newest point.
    private func send(_ type: String, at point: CGPoint?) {
        guard let tab else { return }
        let files = files.map(\.path)
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            let at: CGPoint
            if let point {
                at = point
            } else {
                guard let over = self?.pendingOver else { return }
                self?.pendingOver = nil
                at = over
            }
            // View points under a fit's or device's scale (cx-mogig), as link hints and agent input convert.
            let scale = tab.emulationInputScale
            _ = try? await tab.devTools(method: "Input.dispatchDragEvent", params: [
                "type": type, "x": at.x * scale, "y": at.y * scale,
                "data": ["items": [[String: any Sendable]](), "files": files, "dragOperationsMask": Self.operations] as [String: any Sendable],
            ])
        }
    }
}

extension CEFHostView {
    /// The drag's location in page coordinates: view points from the top left.
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
}
