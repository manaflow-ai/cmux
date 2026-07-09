import Foundation

/// The minimal attachment surface the textbox submission planner reads.
///
/// Submission planning only needs the text an attachment contributes, the path
/// it submits, an optional local file URL, and whether it is an image. The app's
/// `TextBoxAttachment` conforms to this protocol; the planner never sees the
/// app-only presentation fields (thumbnail, display name, cleanup flags).
public protocol TextBoxSubmissionAttachment {
    /// The text inserted into the terminal for this attachment.
    var submissionText: String { get }
    /// The path string this attachment submits.
    var submissionPath: String { get }
    /// The local file URL backing this attachment, if any.
    var localURL: URL? { get }
    /// Whether this attachment represents an image file.
    var isImage: Bool { get }
}
