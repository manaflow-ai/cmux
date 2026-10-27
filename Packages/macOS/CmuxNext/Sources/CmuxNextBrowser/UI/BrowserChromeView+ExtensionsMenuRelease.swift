public import CmuxNextCompat

extension BrowserChromeView {
    /// Lets this pane's Extensions bubble build its rows only after its first open and drop them once unused, on
    /// the app's overlay page terms (feature `memoryOverlayPagesOnFirstUse`, ``OverlayPageRelease``).
    public func releaseExtensionsMenuWhenUnused(_ terms: OverlayPageReleaseTerms) {
        extensionToolbar.menuController.releaseWhenUnused(terms)
    }
}
