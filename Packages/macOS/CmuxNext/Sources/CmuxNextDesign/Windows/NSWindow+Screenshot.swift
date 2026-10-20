public import AppKit

/// Screenshots of the app's own windows for `cmux window|pane|tab
/// screenshot`. Not implemented yet.
extension NSWindow {
    /// This window as on screen, at the backing scale.
    /// - Throws: ``WindowScreenshotFailure``.
    public func screenshotImage(includeChild: (NSWindow) -> Bool = { _ in true }) async throws -> CGImage {
        throw WindowScreenshotFailure.blank
    }

    /// This window alone through ScreenCaptureKit's current-process content.
    @available(macOS 14.4, *)
    public func screenCaptureKitSnapshot() async -> CGImage? {
        nil
    }
}
