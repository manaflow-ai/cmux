/// An image format accepted by `simctl io screenshot`.
public enum SimulatorScreenshotFormat: String, Codable, CaseIterable, Hashable, Sendable {
    /// Portable Network Graphics.
    case png
    /// Tagged Image File Format.
    case tiff
    /// Bitmap image.
    case bmp
    /// Graphics Interchange Format.
    case gif
    /// JPEG image.
    case jpeg
}
