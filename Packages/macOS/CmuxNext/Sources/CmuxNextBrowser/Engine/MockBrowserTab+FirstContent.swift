/// A mock page's first content frame comes when a test says (``simulateFirstContentFrame()``). It loads no document
/// as far as `create.tab` goes, so a new mock tab still shows at the commit that shows it.
extension MockBrowserTab: BrowserFirstContentFrameReporting {
    public var loadsDocument: Bool { false }

    public func whenFirstContentFrame(_ body: @escaping @MainActor (_ shown: Bool) -> Void) {
        firstContentFrame.add(body)
    }

    /// The page showed its first content: its waiters run with true.
    public func simulateFirstContentFrame() {
        firstContentFrame.contentShown()
    }
}

extension MockBrowserTab: BrowserPageCovering {}
