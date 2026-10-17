import Foundation

/// An attachment the user is sending with a prompt.
///
/// Carries the binary payload from the composer to the ``ChatEventSource``,
/// which delivers it to the host out-of-band (image paste or chunked file
/// upload RPC).
public struct ChatOutboundAttachment: Sendable, Equatable {
    /// The encoding or transport kind of ``data``.
    public enum Format: String, Sendable, Equatable {
        /// PNG-encoded image data.
        case png
        /// JPEG-encoded image data.
        case jpeg
        /// Arbitrary file bytes. The source uploads these bytes to the host
        /// before injecting the returned path into the agent terminal.
        case file
    }

    /// The encoded image or raw file payload.
    public let data: Data

    /// The encoding or transport kind of ``data``.
    public let format: Format

    /// The original file name for a ``file`` attachment, when available. The
    /// host sanitizes this name before materializing it.
    public let fileName: String?

    /// Creates an outbound attachment.
    ///
    /// - Parameters:
    ///   - data: The encoded image or raw file payload.
    ///   - format: The encoding or transport kind of `data`.
    ///   - fileName: The user-visible name for a file attachment.
    public init(data: Data, format: Format, fileName: String? = nil) {
        self.data = data
        self.format = format
        self.fileName = fileName
    }
}
