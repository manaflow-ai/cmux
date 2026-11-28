/// Errors returned by the authenticated Cloud image-paste transaction.
public enum CloudImagePasteError: Error, Equatable, Sendable {
    /// The leased terminal link is unavailable.
    case unavailable
    /// The daemon does not advertise the image-paste capability.
    case unsupported
    /// The image exceeds the bounded transfer size.
    case sizeLimit
    /// The payload is not a supported image format.
    case unsupportedType
    /// The daemon's temporary image quota is exhausted.
    case capacity
    /// The clipboard selection contains more images than one operation accepts.
    case tooManyImages
    /// The daemon could not safely persist the image.
    case storage
    /// The bounded transaction deadline elapsed.
    case timedOut
    /// Delivery may have reached the terminal but was not acknowledged.
    case deliveryUncertain
    /// Image attachments are unavailable in the command composer.
    case useTerminal
    /// Another image transaction is already active for the attachment.
    case busy

    /// Maps a daemon error code to the stable client error taxonomy.
    ///
    /// - Parameter serverCode: The opaque daemon error code, if present.
    public init(serverCode: String?) {
        switch serverCode {
        case "image-type-rejected": self = .unsupportedType
        case "image-size-limit": self = .sizeLimit
        case "image-capacity-limit": self = .capacity
        case "image-storage-unavailable": self = .storage
        case "image-paste-uncertain", "image-already-pasted": self = .deliveryUncertain
        case "image-upload-expired": self = .timedOut
        default: self = .unavailable
        }
    }
}
