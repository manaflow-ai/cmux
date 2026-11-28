/// An image or file the user attached to a prompt.
///
/// The binary payload travels out-of-band (image paste RPC); the transcript
/// message carries only display metadata.
public struct ChatAttachment: Sendable, Equatable, Codable {
    /// The attachment's media category.
    public enum Media: String, Sendable, Equatable, Codable {
        /// A raster image (photo, screenshot).
        case image
        /// Any other file.
        case file
    }

    /// The attachment's media category.
    public let media: Media

    /// Display name, when one is known (e.g. the original filename).
    public let displayName: String?

    /// Path on the host where the attachment was materialized, when known.
    /// Lets renderers reference what the agent sees.
    public let hostPath: String?

    /// Creates attachment metadata.
    ///
    /// - Parameters:
    ///   - media: The media category.
    ///   - displayName: Display name when known.
    ///   - hostPath: Host-side materialized path when known.
    public init(media: Media, displayName: String? = nil, hostPath: String? = nil) {
        self.media = media
        self.displayName = displayName
        self.hostPath = hostPath
    }

    private enum CodingKeys: String, CodingKey {
        case media
        case displayName = "display_name"
        case hostPath = "host_path"
    }
}
