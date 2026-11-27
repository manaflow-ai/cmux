public import Foundation

public struct BrowserScreenshotEncodedImage: Sendable {
    public let png: Data
    public let tiff: Data

    public init(
        png: Data,
        tiff: Data
    ) {
        self.png = png
        self.tiff = tiff
    }
}
