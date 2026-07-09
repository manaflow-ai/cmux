public import AppKit

extension CGPoint {
    /// A compact `(x,y)` description of this point with each coordinate rounded
    /// to one decimal place, used by the titlebar window-drag-handle subsystem
    /// for debug logs, Sentry breadcrumbs, and UI-test telemetry payloads.
    ///
    /// Pure value formatting, faithful lift of the app-side
    /// `windowDragHandleFormatPoint` free function.
    public var titlebarDragPointDescription: String {
        String(format: "(%.1f,%.1f)", x, y)
    }
}
