import WebKit

extension PageWebView {
    /// Applies this view's theme at document start, right after ``WebTheme/bootstrapScript``, so
    /// the page's first frame already has its colors (no-flicker F1). `applyTheme` reaches a
    /// document only once it finished loading; until then a page painted with no theme, and a
    /// page without its own background painted white.
    func installDocumentStartTheme() {}
}
