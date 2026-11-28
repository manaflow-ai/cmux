public import AppKit
public import CmuxNextPages
import os

nonisolated private let documentCoverLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.webview")

/// A chat that drew keeps its last frame on screen while its page gets a new document (``AgentPaneDocumentCover``).
extension AgentPaneView {
    /// The page's document is about to change or is gone (``PageWebView/onDocumentWillChange``, and the old
    /// host's navigation and crash calls).
    public func documentWillChange(_ change: PageDocumentChange) {
        switch change {
        case .reload:
            // The old document still draws until the new one commits: its picture now, kept by the cover when
            // it lands before the commit, and the last one meanwhile. With none, nothing covers a page that
            // still draws; its commit does.
            rememberLastFrame(fresh: true) { [weak self] in self?.coverNewDocument(.reload, onlyWithPicture: true) }
            coverNewDocument(.reload, onlyWithPicture: true)
        case .contentEnded:
            documentCover.pageEndedNow()
            coverNewDocument(.contentEnded)
        case .rendererRestart:
            documentCover.pageEndedNow()
            coverNewDocument(.rendererRestart)
        case .committed:
            documentCover.documentCommitted()
            coverNewDocument(.newDocument, afterCommit: true)
        }
    }

    /// The page's last error boundary caught a render error (`pane.renderFailed`, webviews PaneBoundary.tsx). React
    /// took the whole app down with it, so the document draws nothing (the window's wallpaper through a clear page) until
    /// the boundary's retry reloads it, a second at first and longer on each failure in a row. That empty page was the
    /// blank pane Leo saw, then the bare `location.reload()` (Leo, 2026-11-22: "the agent pane just blanked out entirely
    /// yet again. i dont know what that was, some sort of ultra hard reload?"). The pane keeps its last frame over it
    /// now (the loading state when it has none) until the reloaded document paints, as for every other new document;
    /// the remembered frame is from before the failure (none is taken while a cover shows).
    func pageRenderFailed() {
        documentCoverLogger.error("agent pane page render failed; covering it session=\(self.model.sessionId ?? "none", privacy: .public) engine=\(self.engineName, privacy: .public)")
        coverNewDocument(.renderFailed)
    }

    /// Puts the cover over a page that drew before: its last frame when it has one of this size and look,
    /// else the loading state. `onlyWithPicture`: nothing without a picture (the old document still draws).
    func coverNewDocument(_ cause: AgentPaneDocumentCover.Cause, onlyWithPicture: Bool = false, afterCommit: Bool = false) {
        let cover = documentCover
        // A first document has the loading state; a crash notice says what happened; a web update's reload holds
        // its own picture of the chat (``AgentPaneView/reloadUnderCover(_:)``, cmux#50512) until the page drew.
        guard model.hasPainted, loadingView.superview !== self, crashNotice == nil, reloadCover == nil else { return }
        let place = topBar.pageFrame(in: bounds)
        let picture = cover.picture(size: place.size, appearance: launchImageAppearance)
        if cover.isShown {
            // A fresh picture of the old document that landed before its reload committed replaces the older one.
            if let picture, cover.documentsSince == 0, cover.cause == .reload { drawCoverPicture(picture, in: cover) }
            return
        }
        if onlyWithPicture, picture == nil { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.began(cause, picture: picture != nil, afterCommit: afterCommit)
        let view = cover.view
        view.frame = place
        view.paint(performWithTheme { AgentPaneTheme.pageColor(themeTokens, surface: surfaceKind, backgrounds: themeScope.surfaceBackgrounds) }.nsColor)
        view.marksLoading = { [weak cover] in cover?.showsPicture == false }
        drawCoverPicture(picture, in: cover)
        view.isHidden = false
        addSubview(view, positioned: .above, relativeTo: nil)
        view.showMarkLater()
        if cover.waitsOnUncommittedReload {
            cover.uncommittedTimer.schedule(after: cover.uncommittedLimit) { @MainActor [weak self] in
                self?.endUncommittedReloadCover()
            }
        }
        if pageDrawsOverCovers {
            // Chromium draws in its own window over any cover: the page waits outside the window.
            if !holdsPageAway {
                holdsPageAway = true
                cover.heldPageAway = true
                pageContent.frame = Self.awayFrame(of: place)
                page?.chromiumWindowMoved()
            }
        } else if pageContent.alphaValue != 0 {
            pageContent.alphaValue = 0
            cover.hidPage = true
        }
        CATransaction.commit()
        let age = cover.frameAgeMilliseconds.map(String.init) ?? "-"
        documentCoverLogger.error("agent pane keeps its last frame over a new document cause=\(cause.rawValue, privacy: .public) session=\(self.model.sessionId ?? "none", privacy: .public) engine=\(self.engineName, privacy: .public) picture=\(picture != nil) picture_age_ms=\(age, privacy: .public)")
        flickerLog?.record("reload-cover", ["cause": cause.rawValue, "page": AgentPageFlickerLog.pageName(self),
                                            "engine": engineName, "picture": picture != nil])
    }

    /// A reload's cover whose new document never committed: the old document still draws, so it shows again
    /// rather than a stale picture for good. A later commit covers the new document again.
    func endUncommittedReloadCover() {
        let cover = documentCover
        guard cover.isShown, cover.waitsOnUncommittedReload else { return }
        cover.uncommittedEnded()
        endDocumentCover(painted: false, reason: "reload-never-committed")
    }

    private func drawCoverPicture(_ picture: NSImage?, in cover: AgentPaneDocumentCover) {
        let layer = cover.view.layer
        layer?.contentsGravity = .resize
        layer?.contents = picture
        if picture != nil {
            cover.pictureShown()
            cover.view.hideMark()
        }
    }

    /// From the model, at each `pane.painted`: the first report of a document that committed after the cover
    /// went up ends it, and the page's new frame is remembered a moment later.
    func documentCoverPaintReported() {
        if documentCover.isShown, documentCover.documentsSince > 0 { endDocumentCover(painted: true) }
        rememberLastFrameSoon()
    }

    /// Takes the cover away and shows the page again; `painted`: the new document reported its first paint.
    func endDocumentCover(painted: Bool, reason: String = "painted") {
        let cover = documentCover
        guard cover.isShown else { return }
        let cause = cover.cause
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.view.hideMark()
        cover.view.removeFromSuperview()
        cover.view.layer?.contents = nil
        if cover.heldPageAway {
            cover.heldPageAway = false
            if holdsPageAway {
                holdsPageAway = false
                pageContent.frame = topBar.pageFrame(in: bounds)
                applyNativeRects()
                needsLayout = true
                page?.chromiumWindowMoved()
            }
        }
        if cover.hidPage {
            cover.hidPage = false
            pageContent.alphaValue = 1
            PageWebView.syncChromiumVisibility(in: pageContent)
        }
        CATransaction.commit()
        guard let recovery = cover.ended(painted: painted) else {
            documentCoverLogger.error("agent pane cover over a new document ended unpainted cause=\(cause?.rawValue ?? "-", privacy: .public) reason=\(reason, privacy: .public) session=\(self.model.sessionId ?? "none", privacy: .public)")
            return
        }
        documentCoverLogger.error("agent pane page drew again after cause=\(recovery.cause.rawValue, privacy: .public) first_paint_ms=\(recovery.milliseconds) picture=\(recovery.picture) session=\(self.model.sessionId ?? "none", privacy: .public) engine=\(self.engineName, privacy: .public)")
        flickerLog?.record("reload-cover-ended", ["cause": recovery.cause.rawValue, "page": AgentPageFlickerLog.pageName(self),
                                                  "first_paint_ms": recovery.milliseconds, "picture": recovery.picture])
    }

    /// The cover follows the page's place; a picture of another size gives way to the loading state.
    func layOutDocumentCover(_ place: NSRect) {
        let cover = documentCover
        guard cover.isShown, cover.view.superview === self else { return }
        if cover.view.frame.size != place.size, cover.showsPicture {
            cover.view.layer?.contents = nil
            cover.droppedPicture()
            cover.view.showMarkLater()
        }
        cover.view.frame = place
    }

    /// Remembers the page's frame a moment from now (after its paint report or the person's click or key in it).
    func rememberLastFrameSoon() {
        guard model.hasPainted else { return }
        documentCover.captureTimer.schedule(after: AgentPaneDocumentCover.captureDelay) { @MainActor [weak self] in
            self?.rememberLastFrame(fresh: false)
        }
    }

    /// Takes the page's picture (``pageImage()``) as the cover's last frame. Not of a page that has not drawn,
    /// one whose renderer ended (its picture is empty), one frozen (its thaw is work for nobody), one out of a
    /// window, or one under the cover (but for a reload asked for while the old document still draws).
    /// `fresh`: a reload was asked for, so the throttle does not apply; `done` runs when the picture was kept.
    func rememberLastFrame(fresh: Bool, done: (@MainActor () -> Void)? = nil) {
        let cover = documentCover
        guard model.hasPainted, !cover.pageEnded, !pageIsFrozen, window != nil, !isHiddenOrHasHiddenAncestor, cover.documentsSince == 0,
              !cover.isShown || (fresh && cover.cause == .reload), cover.mayCapture(fresh: fresh) else { return }
        let size = topBar.pageFrame(in: bounds).size
        guard size.width > 0, size.height > 0 else { return }
        let appearance = launchImageAppearance
        let serial = cover.captureStarted()
        // task-owner: one picture of the page; dropped when a new document committed meanwhile
        Task { [weak self, weak cover] in
            guard let self, let cover else { return }
            let image: NSImage?
            if let take = cover.takePicture { image = await take(self) } else { image = await pageImage() }
            if cover.captureEnded(image, size: size, appearance: appearance, serial: serial) { done?() }
        }
    }
}
