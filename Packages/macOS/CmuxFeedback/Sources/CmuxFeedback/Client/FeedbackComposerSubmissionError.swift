public import Foundation

/// Low-level failure modes raised by ``FeedbackComposerClient`` while preparing
/// and uploading a feedback submission. ``FeedbackComposerBridge`` maps these to
/// user-facing messages; the composer sheet maps them to localized strings.
public enum FeedbackComposerSubmissionError: Error {
    case invalidEndpoint
    case invalidResponse
    case rejected(statusCode: Int)
    case attachmentReadFailed
    case attachmentPreparationFailed
    case transport(URLError)
}
