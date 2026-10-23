public import AppKit
import ScreenCaptureKit
public import CmuxNextDesignTokens

/// Screenshots of the app's own windows for `cmux window|pane|tab
/// screenshot`. Neither path needs the Screen Recording grant, moves focus,
/// activates the app or raises the window, and both read a window that is in
/// the background or covered by other apps' windows.
///
/// 1. The window server's composited image (``compositedSnapshot(includeChild:)``,
///    `CGWindowListCreateImage` looked up at run time). It shows Metal layers
///    (Ghostty terminal surfaces), WebKit pages, vibrancy and glass as on
///    screen, plus the child windows `includeChild` accepts.
/// 2. Else, from macOS 14.4, ScreenCaptureKit with the current process's
///    shareable content (`SCShareableContent.currentProcess`), which is the
///    one ScreenCaptureKit path that needs no Screen Recording consent. It
///    captures the one window, without its child windows.
///
/// An image with no visible pixel counts as no image: the caller gets
/// ``WindowScreenshotFailure/blank``, never a blank PNG.
extension NSWindow {
    /// This window as on screen (window frame, titlebar included), at the
    /// backing scale.
    ///
    /// - Parameter includeChild: Which visible child windows the image
    ///   composites (Chromium page windows, overlay panels).
    /// - Returns: The image; its size is the window frame times the scale.
    /// - Throws: ``WindowScreenshotFailure``.
    public func screenshotImage(includeChild: (NSWindow) -> Bool = { _ in true }) async throws -> CGImage {
        guard windowNumber > 0 else { throw WindowScreenshotFailure.notOnScreen }
        guard !isMiniaturized else { throw WindowScreenshotFailure.minimized }
        guard isVisible else { throw WindowScreenshotFailure.notOnScreen }
        if let image = compositedSnapshot(includeChild: includeChild) {
            // The window server picks its own resolution (a virtual display
            // can give a few pixels less than frame x scale); the contract is
            // the backing scale, so a different size is redrawn to it.
            let scale = backingScaleFactor
            let width = Int((frame.width * scale).rounded()), height = Int((frame.height * scale).rounded())
            if let sized = image.resampled(width: width, height: height) { return sized }
        }
        if #available(macOS 14.4, *), let image = await screenCaptureKitSnapshot() { return image }
        throw WindowScreenshotFailure.blank
    }

    /// This window alone through ScreenCaptureKit's current-process content
    /// (no Screen Recording consent), at the backing scale; nil when the
    /// window server lists no such window of this process or the image is
    /// all transparent.
    @available(macOS 14.4, *)
    public func screenCaptureKitSnapshot() async -> CGImage? {
        guard windowNumber > 0 else { return nil }
        let scale = backingScaleFactor
        let width = Int((frame.width * scale).rounded()), height = Int((frame.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        guard let image = await Self.captureOwnWindow(CGWindowID(windowNumber), width: width, height: height),
              !image.isFullyTransparent else { return nil }
        return image
    }

    /// One window of this process through ScreenCaptureKit.
    @available(macOS 14.4, *)
    @concurrent nonisolated private static func captureOwnWindow(_ id: CGWindowID, width: Int, height: Int) async -> CGImage? {
        guard let content = try? await SCShareableContent.currentProcess,
              let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
