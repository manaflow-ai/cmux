/// Image encoding carried by a mobile browser frame.
public enum MobileBrowserFrameFormat: Equatable, Sendable {
    /// Lossy JPEG used while a page is active.
    case jpeg
    /// Lossless PNG used for the final settled frame.
    case png
    /// A newer encoding retained so older peers can ignore it without failing decode.
    case unknown(String)

    /// The wire value for this format.
    public var rawValue: String {
        switch self {
        case .jpeg: "jpeg"
        case .png: "png"
        case let .unknown(value): value
        }
    }
}

extension MobileBrowserFrameFormat: Codable {
    /// Decodes a known format or preserves an unknown future wire value.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "jpeg": self = .jpeg
        case "png": self = .png
        default: self = .unknown(value)
        }
    }

    /// Encodes the format's wire value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
