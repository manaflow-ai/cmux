/// Why ``NSWindow/screenshotImage(includeChild:)`` gave no image. The App
/// turns each case into a localized `screenshot.unavailable` reason; a
/// screenshot never comes back blank instead.
public nonisolated enum WindowScreenshotFailure: Error, Sendable, Hashable {
    /// The window has no window-server window, or it is ordered out.
    case notOnScreen
    /// The window is minimized to the Dock: the window server keeps no
    /// current image of it.
    case minimized
    /// Neither capture path gave an image with any visible pixel.
    case blank
}
