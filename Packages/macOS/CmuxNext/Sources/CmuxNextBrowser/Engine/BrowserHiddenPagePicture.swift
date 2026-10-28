public import CoreGraphics

/// A hidden page that already holds its last frame (a Chromium page past its hidden grace keeps a
/// volatile snapshot): hibernation takes its picture from there, so the hidden page
/// is not made to draw again for a screenshot after its renderer let its frame go.
@MainActor public protocol BrowserHiddenPagePicture: AnyObject, Sendable {
    /// The page's held last frame as a picture, drawn off the main thread; nil when it holds none (it
    /// shows, is within its grace, or the system purged the frame).
    func hiddenPagePicture() async -> CGImage?
}
