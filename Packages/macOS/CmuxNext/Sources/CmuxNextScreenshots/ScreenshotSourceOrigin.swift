/// Where a Screenshots pane folder came from.
public nonisolated enum ScreenshotSourceOrigin: Sendable, Hashable {
    /// macOS's screenshot folder (`defaults read com.apple.screencapture location`, else the Desktop).
    case system
    /// The folder macOS writes a screenshot into while its floating preview shows
    /// (`$TMPDIR/TemporaryItems/NSIRD_screencaptureui_*`); the file moves to the screenshot
    /// folder when the preview goes away.
    case systemPreview
    /// A third-party tool's save folder.
    case tool(ScreenshotTool)
    /// A tool's capture history (every capture, including ones only copied).
    case toolHistory(ScreenshotTool)
    /// A folder the person added in Settings (`screenshots.folders`).
    case custom
}
