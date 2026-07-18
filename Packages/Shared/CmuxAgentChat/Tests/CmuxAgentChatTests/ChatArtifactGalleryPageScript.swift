@testable import CmuxAgentChat

/// Actor-backed page script that records sequential eager-paging requests.
actor ChatArtifactGalleryPageScript {
    private let pages: [String: ChatArtifactGalleryPage]
    private var cursors: [String] = []

    /// Creates a page script keyed by opaque cursor.
    ///
    /// - Parameter pages: Pages returned for each expected cursor.
    init(pages: [String: ChatArtifactGalleryPage]) {
        self.pages = pages
    }

    /// Records and resolves one cursor request.
    ///
    /// - Parameter cursor: Requested opaque cursor.
    /// - Returns: Scripted page for the cursor.
    /// - Throws: ``ChatArtifactError/invalidParams`` for an unscripted cursor.
    func fetch(cursor: String) throws -> ChatArtifactGalleryPage {
        cursors.append(cursor)
        guard let page = pages[cursor] else {
            throw ChatArtifactError.invalidParams
        }
        return page
    }

    /// Returns cursors in request order.
    func requestedCursors() -> [String] {
        cursors
    }
}
