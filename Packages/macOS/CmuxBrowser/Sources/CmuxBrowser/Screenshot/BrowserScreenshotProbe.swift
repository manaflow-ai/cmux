public import AppKit

/// DOM evidence for one visible text glyph in a browser screenshot.
public struct BrowserScreenshotProbe: Equatable, Sendable {
    /// Stable, opaque DOM-path identifier for the probed glyph.
    public let identifier: String
    /// Text-node content used only to confirm stability across capture.
    ///
    /// Callers must not include this value in logs or user-visible errors.
    public let text: String
    /// A single visible glyph rect in CSS viewport coordinates, with a top-left origin.
    public let rect: NSRect
    /// The text color after compositing CSS color alpha over ``background``.
    public let foreground: BrowserScreenshotRGBA
    /// The opaque solid background color under the glyph.
    public let background: BrowserScreenshotRGBA

    /// Creates text-glyph evidence collected from the DOM.
    ///
    /// - Parameters:
    ///   - identifier: Stable, opaque identity shared by pre- and post-capture probes.
    ///   - text: Text used only to determine whether the probe stayed stable.
    ///   - rect: Visible glyph rectangle in CSS viewport coordinates.
    ///   - foreground: Text color composited over `background`.
    ///   - background: Opaque solid color beneath the glyph.
    public init(
        identifier: String,
        text: String,
        rect: NSRect,
        foreground: BrowserScreenshotRGBA,
        background: BrowserScreenshotRGBA
    ) {
        self.identifier = identifier
        self.text = text
        self.rect = rect
        self.foreground = foreground
        self.background = background
    }
}
