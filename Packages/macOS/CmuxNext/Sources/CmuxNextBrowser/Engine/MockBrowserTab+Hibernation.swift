/// A mock page as browser hibernation sees it: it hibernates only when a test gives it the history to
/// save (``MockBrowserTab/hibernationRestore``), so tests that rank or discard hidden browser tabs run on
/// mock pages, and every other test's mock page still counts as one that cannot hibernate.
extension MockBrowserTab: BrowserHibernationSource {
    public var supportsHibernation: Bool { hibernationRestore != nil }
    public var showsFormSubmission: Bool { false }
    public var allowsNotifications: Bool { false }
    public func hibernationState() -> BrowserRestoreState? { hibernationRestore }
}
