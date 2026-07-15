import Foundation

/// One JPEG snapshot and metadata for a mirrored Mac browser surface.
public struct MobileBrowserPreviewFrame: Codable, Equatable, Sendable {
    /// The stable Mac browser surface identifier.
    public let surfaceID: String
    /// Monotonic sequence assigned by the Mac emitter for this surface.
    public let sequence: UInt64
    /// Whether this is a compact card or full-screen snapshot.
    public let resolution: MobileBrowserPreviewResolution
    /// The page title at capture time.
    public let title: String
    /// The committed page URL at capture time, when available.
    public let url: String?
    /// JPEG bytes, encoded as base64 by JSONEncoder on the wire.
    public let imageData: Data
    /// Encoded image width in pixels.
    public let pixelWidth: Int
    /// Encoded image height in pixels.
    public let pixelHeight: Int

    /// Creates one mirrored-browser snapshot frame.
    /// - Parameters:
    ///   - surfaceID: The stable Mac browser surface identifier.
    ///   - sequence: Monotonic per-surface sequence.
    ///   - resolution: Requested compact or full-screen fidelity.
    ///   - title: Page title at capture time.
    ///   - url: Committed URL at capture time.
    ///   - imageData: JPEG image bytes.
    ///   - pixelWidth: Encoded pixel width.
    ///   - pixelHeight: Encoded pixel height.
    public init(
        surfaceID: String,
        sequence: UInt64,
        resolution: MobileBrowserPreviewResolution,
        title: String,
        url: String?,
        imageData: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.surfaceID = surfaceID
        self.sequence = sequence
        self.resolution = resolution
        self.title = title
        self.url = url
        self.imageData = imageData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Encodes the frame as a JSON-compatible event payload.
    /// - Returns: A dictionary suitable for `MobileHostService.emitEvent`.
    /// - Throws: An encoding error when the frame cannot be represented as JSON.
    public func jsonObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: [], debugDescription: "Expected browser preview object")
            )
        }
        return object
    }

    /// Decodes one bare browser-preview event payload.
    /// - Parameter data: JSON object data.
    /// - Returns: The decoded frame.
    /// - Throws: A decoding error for invalid payloads.
    public static func decode(_ data: Data) throws -> MobileBrowserPreviewFrame {
        try JSONDecoder().decode(Self.self, from: data)
    }

    enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_id"
        case sequence
        case resolution
        case title
        case url
        case imageData = "image_data"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
    }
}
