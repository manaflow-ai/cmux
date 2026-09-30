public import Foundation

/// The outcome of materializing every pasteboard image into temporary files.
///
/// `rejectedImagePayload` means at least one real image was found but the
/// batch could not be used (an item was too large or failed to write; any
/// files already written are cleaned up), so callers must not fall back to
/// auxiliary plain text or URLs. `rejectedOversizedImagePayload` is the same
/// rejection when the reason is that an item exceeded the clipboard image cap.
public enum TerminalImageFileListMaterialization: Equatable, Sendable {
    /// Every image was written; the URLs preserve pasteboard order.
    case saved([URL])

    /// No decodable image payload was found on the pasteboard.
    case noDecodableImagePayload

    /// A real image payload was found but the batch could not be materialized.
    case rejectedImagePayload

    /// An image in the batch is larger than the clipboard image cap; any files
    /// already written are cleaned up.
    case rejectedOversizedImagePayload
}
