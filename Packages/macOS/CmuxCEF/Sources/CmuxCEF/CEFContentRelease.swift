import Foundation

/// Where a `CEFBrowser` is in releasing its content to save memory.
struct CEFContentRelease: Equatable {
    /// Chromium is closing the browser for `releaseContent()`, not for good.
    var isReleasing = false
    /// The browser is closed to save memory; the page and its history stay.
    var isReleased = false
    /// The page's URL when it was released: the load to fall back to when
    /// Chromium cannot restore the saved history.
    var releasedURL: URL?
    /// A load asked for while the content was released, run on top of the
    /// restored history.
    var loadAfterRestore: URL?
    /// `restoreContent()` was called while Chromium was still closing the browser.
    var restoreWhenReleased = false

    /// The pending load after a restore, clearing the release's leftovers.
    mutating func takeLoadAfterRestore() -> URL? {
        defer {
            loadAfterRestore = nil
            releasedURL = nil
        }
        return loadAfterRestore
    }
}
