import Foundation

/// Packed pixel data for one normalized browser screenshot region.
struct BrowserScreenshotNormalizedPixelRegion {
    let data: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
}
