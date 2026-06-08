public import CmuxMobileShellModel
import Foundation

/// The email-path delivery seam for Send Feedback.
///
/// Non-privileged submissions POST a `message` plus the build/device stamp to
/// the cmux web `/api/feedback` route, which emails the feedback inbox. Injected
/// into the shell store so the email path is failure-tolerant and testable
/// without a network.
public protocol MobileFeedbackEmailSubmitting: Sendable {
    /// Submit a feedback message to the email inbox.
    ///
    /// - Parameters:
    ///   - email: The reply-to address (the signed-in user's email).
    ///   - message: The freeform feedback body. Must be non-empty.
    ///   - stamp: The build + device stamp embedded in the subject and body so
    ///     every report is self-identifying.
    /// - Throws: ``MobileFeedbackEmailError`` on a configuration, transport, or
    ///   server error.
    func submit(email: String, message: String, stamp: MobileFeedbackStamp) async throws
}

/// Failure modes for the email feedback path.
public enum MobileFeedbackEmailError: Error, Equatable, Sendable {
    /// The web API base URL could not be formed into a valid endpoint.
    case invalidEndpoint
    /// The response was not an HTTP response.
    case invalidResponse
    /// The server rejected the submission with a non-2xx status.
    case rejected(statusCode: Int)
    /// The request failed at the transport layer.
    case transport
}
