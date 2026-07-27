public import Foundation

/// The outcome of materializing one pasteboard image into a temporary file.
///
/// `rejectedImagePayload` means a real image was found but could not be used
/// (too large, or the write failed), so callers must not fall back to
/// auxiliary plain text or URLs.
public enum TerminalImageFileMaterialization: Equatable, Sendable {
    /// The image was written to the given temporary file.
    case saved(URL)

    /// No decodable image payload was found on the pasteboard.
    case noDecodableImagePayload

    /// A real image payload was found but could not be materialized.
    case rejectedImagePayload
}
