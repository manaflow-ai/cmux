import AppKit

extension MessagesLabHomeView {
    /// Sets how the chat ends at its top under the avatar and the name pill, live.
    ///
    /// Call after ``applyTheme(active:measuredAccent:)`` (the bands take the theme's background) and
    /// again whenever the style or the theme changes; the same style again only re-reads the colours.
    /// Replaces ``setHeaderGlass()``'s band (``HomeTopFadeStyle/glassBand`` is that band). A pane with
    /// no header (``setBareTop()``) ignores it.
    ///
    /// - Parameter style: the look; Home reads it from Debug Settings > Home > Top of the chat.
    public func setTopFadeStyle(_ style: HomeTopFadeStyle) {
        controller.host.paneHeader.useGlassPill()
        controller.host.applyTopFadeStyle(style)
    }

    /// The current top fade style (nil before ``setTopFadeStyle(_:)``).
    public var topFadeStyle: HomeTopFadeStyle? { controller.host.topFadeStyle }
}
