public import CoreGraphics

extension DensityTokens {
    /// A browser toolbar button's side: Helium's 28 pt at Standard (`kToolbarButtonHeight`), Chrome's 34
    /// at Comfortable. The browser's `OmnibarMetrics` and the pane's trailing control column
    /// (``Metrics/paneTrailingControlCenter``) both read it, so the two ⋮ buttons stay on one column.
    public var toolbarButtonSize: CGFloat { resolve(compact: 28, comfortable: 34) }
}
