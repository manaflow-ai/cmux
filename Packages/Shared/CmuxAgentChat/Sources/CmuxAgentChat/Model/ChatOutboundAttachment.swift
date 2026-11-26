import Foundation

/// An attachment the user is sending with a prompt.
///
/// Carries the binary payload from the composer to the ``ChatEventSource``,
/// which delivers it to the host out-of-band (image paste RPC).
public struct ChatOutboundAttachment: Sendable, Equatable {
    /// The encoded image format of ``data``.
    public enum Format: String, Sendable, Equatable {
        /// PNG-encoded image data.
        case png
        /// JPEG-encoded image data.
        case jpeg
    }

    /// The encoded payload.
    public let data: Data

    /// The encoding of ``data``.
    public let format: Format

    /// Creates an outbound attachment.
    ///
    /// - Parameters:
    ///   - data: The encoded payload.
    ///   - format: The encoding of `data`.
    public init(data: Data, format: Format) {
        self.data = data
        self.format = format
    }
}
