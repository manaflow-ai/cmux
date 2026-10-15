import Foundation

/// Memory Saver: a hidden page's Chromium browser closes to free its
/// renderer while the page, its view, URL, title and back/forward history
/// stay. The owner restores it (when the page is shown, or when the person
/// asks); a load or reload restores it too. Showing `hostView` alone does
/// not, so a "restore when asked" setting is honored.
extension CEFBrowser {
    /// `true` from `releaseContent()` until the browser is created again.
    public var isContentReleased: Bool { contentRelease.isReleased || contentRelease.isReleasing }

    /// Closes the Chromium browser, keeping the page and its history.
    /// Returns false (and changes nothing) for a page that is not live yet, a
    /// popup not yet in its own window, or one whose history Chromium cannot
    /// export now.
    @discardableResult
    public func releaseContent() -> Bool {
        guard !isClosed, !isContentReleased, !isCreationPending, !awaitsWindowMove,
              placeholder == nil, placeholderOwner == nil, let id = browserID, let shim = runtime.shim,
              let saved = navigationState() else { return false }
        pendingRestore = saved
        contentRelease = CEFContentRelease(isReleasing: true, releasedURL: state.url)
        shim.close(id)
        return true
    }

    /// Recreates content released by `releaseContent()` (once Chromium has
    /// finished closing it, when called meanwhile); does nothing otherwise.
    /// Starts at once, also while `hostView` is in no window.
    public func restoreContent() {
        guard !isClosed, !runtime.isShuttingDown else { return }
        if contentRelease.isReleasing {
            contentRelease.restoreWhenReleased = true
            return
        }
        guard contentRelease.isReleased else { return }
        contentRelease.isReleased = false
        createNow()
    }

    /// Chromium's ids of the renderer processes that host this page's frames,
    /// main frame first (`--renderer-client-id=` of each renderer helper);
    /// empty while the page is not live.
    public func rendererClientIDs() -> [Int32] {
        guard let id = browserID, let shim = runtime.shim else { return [] }
        var ids = [Int32](repeating: 0, count: 32)
        let count = ids.withUnsafeMutableBufferPointer { buffer in
            shim.rendererClientIDs(id, buffer.baseAddress, Int32(buffer.count))
        }
        return count > 0 ? Array(ids.prefix(Int(count))) : []
    }

    /// Chromium closed a browser `releaseContent()` asked to close.
    func finishContentRelease() {
        let restoreNow = contentRelease.restoreWhenReleased
        contentRelease.isReleasing = false
        contentRelease.isReleased = true
        contentRelease.restoreWhenReleased = false
        isCreationPending = false
        state.isLoading = false
        state.progress = 0
        emit(.stateChanged(state))
        if restoreNow { restoreContent() }
    }

    /// Back or forward while the content is released: restore, then step.
    func stepAfterRestoring(_ step: Int) {
        contentRelease.historyStepAfterRestore = step
        restoreContent()
    }

    /// Runs what was asked for while the content was released, once its history is back.
    func applyAfterRestore(_ id: Int32, _ shim: CEFShimLibrary) {
        let step = contentRelease.historyStepAfterRestore
        if let url = contentRelease.takeLoadAfterRestore() {
            shim.loadURL(id, url.absoluteString)
        } else if step < 0 {
            shim.goBack(id)
        } else if step > 0 {
            shim.goForward(id)
        }
    }

    /// A load while the content is released: it runs on top of the restored history.
    func loadAfterRestoring(_ url: URL) {
        contentRelease.loadAfterRestore = url
        state.url = url
        emit(.stateChanged(state))
        restoreContent()
    }
}
