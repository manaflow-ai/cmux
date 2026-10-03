/// Whether the document a page shows came from a form submission (POST).
/// Such a document must never be loaded again without the user: restoring
/// its history entry (hibernation wake, tab duplication) would send the form
/// again with no prompt on WebKit.
nonisolated struct FormSubmissionTracker: Equatable, Sendable {
    private var pendingPost = false
    private(set) var showsFormSubmission = false

    /// A navigation's request was allowed.
    mutating func decided(method: String?, isMainFrame: Bool) {
        guard isMainFrame else { return }
        pendingPost = method?.uppercased() == "POST"
    }

    /// The navigation did not commit (cancelled, failed, download).
    mutating func cancelled() {
        pendingPost = false
    }

    /// A main-frame document committed.
    mutating func committed() {
        showsFormSubmission = pendingPost
        pendingPost = false
    }
}
