import Foundation

/// An attachment after upload preparation: re-encoded/optimized image data ready
/// to append to the multipart request body.
struct PreparedFeedbackComposerAttachment {
    let fileName: String
    let mimeType: String
    let data: Data
}
